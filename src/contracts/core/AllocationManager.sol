// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/security/ReentrancyGuardUpgradeable.sol";
import "../mixins/Deprecated_OwnableUpgradeable.sol";
import "../mixins/SplitContractMixin.sol";
import "../mixins/PermissionControllerMixin.sol";
import "../permissions/Pausable.sol";
import "../libraries/SlashingLib.sol";
import "../libraries/OperatorSetLib.sol";
import "./storage/AllocationManagerStorage.sol";

contract AllocationManager is
    Initializable,
    Deprecated_OwnableUpgradeable,
    Pausable,
    AllocationManagerStorage,
    ReentrancyGuardUpgradeable,
    PermissionControllerMixin,
    SplitContractMixin,
    IAllocationManager
{
    using DoubleEndedQueue for DoubleEndedQueue.Bytes32Deque;
    using Snapshots for Snapshots.DefaultWadHistory;
    using OperatorSetLib for OperatorSet;
    using SlashingLib for uint256;
    using EnumerableSet for *;
    using SafeCast for *;

    ///
    ///                         INITIALIZING FUNCTIONS
    ///

    /// @dev Initializes the DelegationManager address, the deallocation delay, and the allocation configuration delay.
    constructor(
        IAllocationManagerView _allocationManagerView,
        IDelegationManager _delegation,
        IStrategy _eigenStrategy,
        IPauserRegistry _pauserRegistry,
        IPermissionController _permissionController,
        uint32 _DEALLOCATION_DELAY,
        uint32 _ALLOCATION_CONFIGURATION_DELAY
    )
        AllocationManagerStorage(_delegation, _eigenStrategy, _DEALLOCATION_DELAY, _ALLOCATION_CONFIGURATION_DELAY)
        Pausable(_pauserRegistry)
        SplitContractMixin(address(_allocationManagerView))
        PermissionControllerMixin(_permissionController)
    {
        _disableInitializers();
    }

    /// @inheritdoc IAllocationManagerActions
    function initialize(
        uint256 initialPausedStatus
    ) external initializer {
        _setPausedStatus(initialPausedStatus);
    }

    /// @inheritdoc IAllocationManagerActions
    function slashOperator(
        address avs,
        SlashingParams calldata params
    ) external onlyWhenNotPaused(PAUSED_OPERATOR_SLASHING) returns (uint256, uint256[] memory) {
        // Check that the operator set exists and the operator is registered to it
        OperatorSet memory operatorSet = OperatorSet(avs, params.operatorSetId);
        require(params.strategies.length == params.wadsToSlash.length, InputArrayLengthMismatch());
        require(_operatorSets[operatorSet.avs].contains(operatorSet.id), InvalidOperatorSet());
        require(isOperatorSlashable(params.operator, operatorSet), OperatorNotSlashable());

        // Assert that the caller is the slasher for the operator set
        require(msg.sender == getSlasher(operatorSet), InvalidCaller());

        return _slashOperator(params, operatorSet);
    }

    /// @inheritdoc IAllocationManagerActions
    /// @notice 修改 Operator 对指定 OperatorSet 和 Strategy 的分配(Allocation)
    /// @dev 这是 Operator 管理其在 AVS 中可惩罚资产量的核心函数
    /// @param operator 要修改分配的操作员地址
    /// @param params 分配参数数组，每个参数包含:
    ///        - operatorSet: 目标 AVS 的 OperatorSet
    ///        - strategies: 要修改分配的策略列表
    ///        - newMagnitudes: 对应策略的新幅度值
    function modifyAllocations(
        address operator,
        AllocateParams[] memory params
    ) external onlyWhenNotPaused(PAUSED_MODIFY_ALLOCATIONS) {
        // 权限检查: 验证调用者有权代表 operator 修改分配
        // 不使用 modifier 是为了避免 "stack too deep" 错误
        _checkCanCall(operator);

        // 获取并验证 operator 的分配延迟配置
        // allocationDelay: 增加分配后，新分配的幅度需要等待此延迟后才能被惩罚
        uint32 operatorAllocationDelay;
        {
            (bool isSet, uint32 delay) = getAllocationDelay(operator);
            require(isSet, UninitializedAllocationDelay());
            operatorAllocationDelay = delay;
        }

        // 遍历每个 OperatorSet 的分配修改请求
        for (uint256 i = 0; i < params.length; i++) {
            // 验证策略数组和幅度数组长度匹配
            require(params[i].strategies.length == params[i].newMagnitudes.length, InputArrayLengthMismatch());

            // 验证 OperatorSet 存在
            // 注意: Operator 不需要已注册到 OperatorSet 就可以分配幅度
            // 实际场景中，AVS 通常只接受已分配足够可惩罚幅度的 Operator 注册
            // 因此 Operator 会先调用 modifyAllocations，再调用 registerForOperatorSets
            OperatorSet memory operatorSet = params[i].operatorSet;
            require(_operatorSets[operatorSet.avs].contains(operatorSet.id), InvalidOperatorSet());

            // 检查 operator 是否可被该 OperatorSet 惩罚
            // 包括两种情况: 1) 已注册 2) 已注销但仍在 DEALLOCATION_DELAY 窗口内
            bool _isOperatorSlashable = isOperatorSlashable(operator, operatorSet);

            // 遍历该 OperatorSet 下的每个策略
            for (uint256 j = 0; j < params[i].strategies.length; j++) {
                IStrategy strategy = params[i].strategies[j];

                // ============ 步骤 1: 清理待定的取消分配 ============
                // 如果该策略有任何已到期的取消分配，先完成它们以释放幅度
                // type(uint16).max 表示清理所有可清理的取消分配
                _clearDeallocationQueue(operator, strategy, type(uint16).max);

                // 获取最新的分配信息
                // 如果有待定的修改已到期，_getUpdatedAllocation 会返回应用后的状态
                (StrategyInfo memory info, Allocation memory allocation) =
                    _getUpdatedAllocation(operator, operatorSet.key(), strategy);
                // 确保没有其他待定的修改操作
                // effectBlock == 0 表示没有待定修改
                require(allocation.effectBlock == 0, ModificationAlreadyPending());

                // ============ 步骤 2: 检查分配是否可惩罚 ============
                // 分配可惩罚需要同时满足:
                // - OperatorSet 包含该 strategy
                // - Operator 可被该 OperatorSet 惩罚
                // - 当前已分配的幅度 > 0
                bool isSlashable = _isAllocationSlashable(operatorSet, strategy, allocation, _isOperatorSlashable);

                // ============ 步骤 3: 计算幅度变化 ============
                // pendingDiff: 正值表示增加分配，负值表示减少分配(取消分配)
                allocation.pendingDiff = _calcDelta(allocation.currentMagnitude, params[i].newMagnitudes[j]);
                require(allocation.pendingDiff != 0, SameMagnitude());

                // ============ 步骤 4: 处理取消分配/分配 ============
                if (allocation.pendingDiff < 0) {
                    // --- 场景 A: 取消分配 (减少幅度) ---
                    if (isSlashable) {
                        // A1. 可惩罚的取消分配: 需要延迟生效
                        // 将取消分配请求加入队列，在 DEALLOCATION_DELAY 期间内仍可被惩罚
                        deallocationQueue[operator][strategy].pushBack(operatorSet.key());

                        // 可惩罚窗口: [block.number, block.number + DEALLOCATION_DELAY]
                        // effectBlock 设置为窗口结束后的下一个区块
                        // 例如: 当前区块 100, DEALLOCATION_DELAY = 21 天 (约 50400 区块)
                        //      effectBlock = 100 + 50400 + 1 = 50501
                        allocation.effectBlock = uint32(block.number) + DEALLOCATION_DELAY + 1;
                    } else {
                        // A2. 不可惩罚的取消分配: 立即生效
                        // 直接减少 encumberedMagnitude (已占用的幅度)
                        info.encumberedMagnitude = _addInt128(info.encumberedMagnitude, allocation.pendingDiff);

                        // 立即更新当前幅度
                        allocation.currentMagnitude = params[i].newMagnitudes[j];
                        allocation.pendingDiff = 0;
                        allocation.effectBlock = uint32(block.number);
                    }
                } else if (allocation.pendingDiff > 0) {
                    // --- 场景 B: 增加分配 ---
                    // 立即占用幅度，但新增的幅度需要等待 allocationDelay 后才能被惩罚
                    info.encumberedMagnitude = _addInt128(info.encumberedMagnitude, allocation.pendingDiff);

                    // 验证没有超过最大可用幅度
                    // maxMagnitude = operator 该策略下的总可用幅度
                    // encumberedMagnitude = 已分配到各个 OperatorSet 的幅度总和
                    require(info.encumberedMagnitude <= info.maxMagnitude, InsufficientMagnitude());

                    // 设置生效区块: 当前区块 + operator 配置的分配延迟
                    // 例如: operatorAllocationDelay = 7200 区块 (约 1 天)
                    //      effectBlock = block.number + 7200
                    allocation.effectBlock = uint32(block.number) + operatorAllocationDelay;
                }

                // ============ 步骤 5: 更新状态 ============
                // 持久化 allocation、info、encumberedMagnitude
                // 同时维护 allocatedStrategies 和 allocatedSets 的可枚举集合
                _updateAllocationInfo(operator, operatorSet.key(), strategy, info, allocation);

                // ============ 步骤 6: 发出事件 ============
                // 通知链下索引器分配已更新
                // 事件参数包含最终的幅度值 (currentMagnitude + pendingDiff)
                emit AllocationUpdated(
                    operator,
                    operatorSet,
                    strategy,
                    _addInt128(allocation.currentMagnitude, allocation.pendingDiff),
                    allocation.effectBlock
                );
            }
        }
    }

    /// @inheritdoc IAllocationManagerActions
    function clearDeallocationQueue(
        address operator,
        IStrategy[] calldata strategies,
        uint16[] calldata numToClear
    ) external onlyWhenNotPaused(PAUSED_MODIFY_ALLOCATIONS) {
        require(strategies.length == numToClear.length, InputArrayLengthMismatch());
        for (uint256 i = 0; i < strategies.length; ++i) {
            _clearDeallocationQueue({operator: operator, strategy: strategies[i], numToClear: numToClear[i]});
        }
    }

    /// @inheritdoc IAllocationManagerActions
    //   - EigenLayer 新架构中操作员注册到 AVS 的 OperatorSets（操作员集）的主要入口函数
    //   - 通过 AllocationManager 统一管理
    //   - 支持 Operator Sets 和惩罚机制
    function registerForOperatorSets(
        address operator,
        RegisterParams calldata params
    ) external onlyWhenNotPaused(PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION) checkCanCall(operator) {
        // Check if the operator has registered.
        //操作员必须先通过 DelegationManager.registerAsOperator() 完成 EigenLayer 注册
        require(delegation.isOperator(operator), InvalidOperator());

        for (uint256 i = 0; i < params.operatorSetIds.length; i++) {
            // Check the operator set exists and the operator is not currently registered to it
            OperatorSet memory operatorSet = OperatorSet(params.avs, params.operatorSetIds[i]);
            require(_operatorSets[operatorSet.avs].contains(operatorSet.id), InvalidOperatorSet());
            require(!isOperatorSlashable(operator, operatorSet), AlreadyMemberOfSet());

            // Add operator to operator set
            // 添加操作员到 OperatorSet（双向映射）
            //   OperatorSet.key() 计算：
            //   keccak256(abi.encodePacked(operatorSet.avs, operatorSet.id));

            registeredSets[operator].add(operatorSet.key());
            _operatorSetMembers[operatorSet.key()].add(operator);
            emit OperatorAddedToOperatorSet(operator, operatorSet);

            // Mark the operator registered
            registrationStatus[operator][operatorSet.key()].registered = true;
        }

        // Call the AVS to complete registration. If the AVS reverts, registration will fail.
        getAVSRegistrar(params.avs).registerOperator(operator, params.avs, params.operatorSetIds, params.data);
    }

    /// @inheritdoc IAllocationManagerActions
    function deregisterFromOperatorSets(
        DeregisterParams calldata params
    ) external onlyWhenNotPaused(PAUSED_OPERATOR_SET_REGISTRATION_AND_DEREGISTRATION) {
        // Check that the caller is either authorized on behalf of the operator or AVS
        require(_canCall(params.operator) || _canCall(params.avs), InvalidCaller());

        for (uint256 i = 0; i < params.operatorSetIds.length; i++) {
            // Check the operator set exists and the operator is registered to it
            OperatorSet memory operatorSet = OperatorSet(params.avs, params.operatorSetIds[i]);
            require(_operatorSets[params.avs].contains(operatorSet.id), InvalidOperatorSet());
            require(registrationStatus[params.operator][operatorSet.key()].registered, NotMemberOfSet());

            // Remove operator from operator set
            registeredSets[params.operator].remove(operatorSet.key());
            _operatorSetMembers[operatorSet.key()].remove(params.operator);
            emit OperatorRemovedFromOperatorSet(params.operator, operatorSet);

            // Mark operator deregistered until the DEALLOCATION_DELAY passes
            // forgefmt: disable-next-item
            registrationStatus[params.operator][operatorSet.key()] = RegistrationStatus({
                registered: false,
                slashableUntil: uint32(block.number) + DEALLOCATION_DELAY
            });
        }

        // Call the AVS to complete deregistration
        getAVSRegistrar(params.avs).deregisterOperator(params.operator, params.avs, params.operatorSetIds);
    }

    /// @inheritdoc IAllocationManagerActions
    function setAllocationDelay(
        address operator,
        uint32 delay
    ) external {
        /// If the caller is the delegationManager, the operator is newly registered
        /// This results in *newly-registered* operators in the core protocol to have their allocation delay effective immediately
        bool newlyRegistered = (msg.sender == address(delegation));

        // If we're not newly registered, check that the caller (not the delegationManager) is authorized to set the allocation delay for the operator
        if (!newlyRegistered) {
            _checkCanCall(operator);
            require(delegation.isOperator(operator), InvalidOperator());
        }

        _setAllocationDelay(operator, delay, newlyRegistered);
    }

    /// @inheritdoc IAllocationManagerActions
    function setAVSRegistrar(
        address avs,
        IAVSRegistrar registrar
    ) external checkCanCall(avs) {
        // Check that the registrar is correctly configured to prevent an AVSRegistrar contract
        // from being used with the wrong AVS
        require(registrar.supportsAVS(avs), InvalidAVSRegistrar());
        _avsRegistrar[avs] = registrar;
        emit AVSRegistrarSet(avs, getAVSRegistrar(avs));
    }

    /// @inheritdoc IAllocationManagerActions
    function updateAVSMetadataURI(
        address avs,
        string calldata metadataURI
    ) external checkCanCall(avs) {
        if (!_avsRegisteredMetadata[avs]) _avsRegisteredMetadata[avs] = true;
        emit AVSMetadataURIUpdated(avs, metadataURI);
    }

    /// @inheritdoc IAllocationManagerActions
    /// @notice This function will be deprecated in Early Q2 2026 in favor of `createOperatorSets` which takes in `CreateSetParamsV2`
    function createOperatorSets(
        address avs,
        CreateSetParams[] calldata params
    ) external checkCanCall(avs) {
        createOperatorSets(avs, _convertCreateSetParams(params, avs));
    }

    /// @inheritdoc IAllocationManagerActions
    function createOperatorSets(
        address avs,
        CreateSetParamsV2[] memory params
    ) public checkCanCall(avs) {
        require(_avsRegisteredMetadata[avs], NonexistentAVSMetadata());
        for (uint256 i = 0; i < params.length; i++) {
            _createOperatorSet(avs, params[i], DEFAULT_BURN_ADDRESS);
        }
    }

    /// @inheritdoc IAllocationManagerActions
    /// @notice This function will be deprecated in Early Q2 2026 in favor of `createRedistributingOperatorSets` which takes in `CreateSetParamsV2`
    function createRedistributingOperatorSets(
        address avs,
        CreateSetParams[] calldata params,
        address[] calldata redistributionRecipients
    ) external checkCanCall(avs) {
        createRedistributingOperatorSets(avs, _convertCreateSetParams(params, avs), redistributionRecipients);
    }

    /// @inheritdoc IAllocationManagerActions
    function createRedistributingOperatorSets(
        address avs,
        CreateSetParamsV2[] memory params,
        address[] calldata redistributionRecipients
    ) public checkCanCall(avs) {
        require(params.length == redistributionRecipients.length, InputArrayLengthMismatch());
        require(_avsRegisteredMetadata[avs], NonexistentAVSMetadata());
        for (uint256 i = 0; i < params.length; i++) {
            address recipient = redistributionRecipients[i];
            require(recipient != address(0), InputAddressZero());
            require(recipient != DEFAULT_BURN_ADDRESS, InvalidRedistributionRecipient());
            _createOperatorSet(avs, params[i], recipient);
        }
    }

    /// @inheritdoc IAllocationManagerActions
    function addStrategiesToOperatorSet(
        address avs,
        uint32 operatorSetId,
        IStrategy[] calldata strategies
    ) external checkCanCall(avs) {
        OperatorSet memory operatorSet = OperatorSet(avs, operatorSetId);
        require(_operatorSets[avs].contains(operatorSet.id), InvalidOperatorSet());

        for (uint256 i = 0; i < strategies.length; i++) {
            _addStrategyToOperatorSet(
                operatorSet, strategies[i], isRedistributingOperatorSet(OperatorSet(avs, operatorSetId))
            );
        }
    }

    /// @inheritdoc IAllocationManagerActions
    function removeStrategiesFromOperatorSet(
        address avs,
        uint32 operatorSetId,
        IStrategy[] calldata strategies
    ) external checkCanCall(avs) {
        OperatorSet memory operatorSet = OperatorSet(avs, operatorSetId);
        require(_operatorSets[avs].contains(operatorSet.id), InvalidOperatorSet());
        bytes32 operatorSetKey = operatorSet.key();
        for (uint256 i = 0; i < strategies.length; i++) {
            require(_operatorSetStrategies[operatorSetKey].remove(address(strategies[i])), StrategyNotInOperatorSet());
            emit StrategyRemovedFromOperatorSet(operatorSet, strategies[i]);
        }
    }

    /// @inheritdoc IAllocationManagerActions
    function updateSlasher(
        OperatorSet memory operatorSet,
        address slasher
    ) external checkCanCall(operatorSet.avs) {
        require(_operatorSets[operatorSet.avs].contains(operatorSet.id), InvalidOperatorSet());
        // Prevent updating a slasher if one is not already set
        // A slasher is set either on operatorSet creation or, for operatorSets created prior to v1.9.0, via `migrateSlashers`
        require(getSlasher(operatorSet) != address(0), SlasherNotSet());
        _updateSlasher({operatorSet: operatorSet, slasher: slasher, instantEffectBlock: false});
    }

    /// @inheritdoc IAllocationManagerActions
    function migrateSlashers(
        OperatorSet[] memory operatorSets
    ) external {
        for (uint256 i = 0; i < operatorSets.length; i++) {
            // If the operatorSet does not exist, continue
            if (!_operatorSets[operatorSets[i].avs].contains(operatorSets[i].id)) {
                continue;
            }

            // If the slasher is already set, continue
            if (getSlasher(operatorSets[i]) != address(0)) {
                continue;
            }

            // Get the slasher from the permission controller.
            address[] memory slashers =
                permissionController.getAppointees(operatorSets[i].avs, address(this), this.slashOperator.selector);

            address slasher;
            // If there are no slashers or the first slasher is the 0 address, set the slasher to the AVS
            if (slashers.length == 0 || slashers[0] == address(0)) {
                slasher = operatorSets[i].avs;
                // Else, set the slasher to the first slasher
            } else {
                slasher = slashers[0];
            }

            _updateSlasher({operatorSet: operatorSets[i], slasher: slasher, instantEffectBlock: true});
            emit SlasherMigrated(operatorSets[i], slasher);
        }
    }

    ///
    ///                         INTERNAL FUNCTIONS
    ///

    /// @dev Slashes an operator.
    /// @param params The slashing parameters. See IAllocationManager.sol#slashOperator for specifics.
    /// @param operatorSet The operator set from which the operator is being slashed.
    /// @return slashId The operator set's unique identifier for the slash.
    /// @return shares The number of shares to be burned or redistributed for each strategy that was slashed.
    function _slashOperator(
        SlashingParams calldata params,
        OperatorSet memory operatorSet
    ) internal returns (uint256 slashId, uint256[] memory shares) {
        uint256[] memory wadSlashed = new uint256[](params.strategies.length);
        shares = new uint256[](params.strategies.length);

        // Increment the slash count for the operator set.
        slashId = ++_slashIds[operatorSet.key()];

        // For each strategy in the operator set, slash any existing allocation
        for (uint256 i = 0; i < params.strategies.length; i++) {
            // Check that `strategies` is in ascending order.
            require(
                i == 0 || uint160(address(params.strategies[i])) > uint160(address(params.strategies[i - 1])),
                StrategiesMustBeInAscendingOrder()
            );
            // Check that `wadToSlash` is within acceptable bounds.
            require(0 < params.wadsToSlash[i] && params.wadsToSlash[i] <= WAD, InvalidWadToSlash());
            // Check that the operator set contains the strategy.
            require(
                _operatorSetStrategies[operatorSet.key()].contains(address(params.strategies[i])),
                StrategyNotInOperatorSet()
            );

            // 1. Get the operator's allocation info for the strategy and operator set
            (StrategyInfo memory info, Allocation memory allocation) =
                _getUpdatedAllocation(params.operator, operatorSet.key(), params.strategies[i]);

            // 2. Skip if the operator does not have a slashable allocation
            // NOTE: this "if" is equivalent to: `if (!_isAllocationSlashable)`, because the other
            // conditions in this method are already true (isOperatorSlashable + operatorSetStrategies.contains)
            if (allocation.currentMagnitude == 0) {
                continue;
            }

            // 3. Calculate the amount of magnitude being slashed, and subtract from
            // the operator's currently-allocated magnitude, as well as the strategy's
            // max and encumbered magnitudes
            uint64 slashedMagnitude = uint64(uint256(allocation.currentMagnitude).mulWadRoundUp(params.wadsToSlash[i]));
            uint64 prevMaxMagnitude = info.maxMagnitude;
            wadSlashed[i] = uint256(slashedMagnitude).divWad(info.maxMagnitude);

            allocation.currentMagnitude -= slashedMagnitude;
            info.maxMagnitude -= slashedMagnitude;
            info.encumberedMagnitude -= slashedMagnitude;

            // 4. If there is a pending deallocation, reduce the pending deallocation proportionally.
            // This ensures that when the deallocation is completed, less magnitude is freed.
            if (allocation.pendingDiff < 0) {
                uint64 slashedPending =
                    uint64(uint256(uint128(-allocation.pendingDiff)).mulWadRoundUp(params.wadsToSlash[i]));
                allocation.pendingDiff += int128(uint128(slashedPending));

                emit AllocationUpdated(
                    params.operator,
                    operatorSet,
                    params.strategies[i],
                    _addInt128(allocation.currentMagnitude, allocation.pendingDiff),
                    allocation.effectBlock
                );
            }

            // 5. Update state
            _updateAllocationInfo(params.operator, operatorSet.key(), params.strategies[i], info, allocation);

            // Emit an event for the updated allocation
            emit AllocationUpdated(
                params.operator,
                operatorSet,
                params.strategies[i],
                allocation.currentMagnitude,
                uint32(block.number)
            );

            _updateMaxMagnitude(params.operator, params.strategies[i], info.maxMagnitude);

            // 6. Slash operators shares in the DelegationManager
            shares[i] = delegation.slashOperatorShares({
                operator: params.operator,
                operatorSet: operatorSet,
                slashId: slashId,
                strategy: params.strategies[i],
                prevMaxMagnitude: prevMaxMagnitude,
                newMaxMagnitude: info.maxMagnitude
            });
        }

        emit OperatorSlashed(params.operator, operatorSet, params.strategies, wadSlashed, params.description);
    }

    /// @dev Adds a strategy to an operator set.
    /// @param operatorSet The operator set to add the strategy to.
    /// @param strategy The strategy to add to the operator set.
    /// @param isRedistributing Whether the operator set is redistributing.
    function _addStrategyToOperatorSet(
        OperatorSet memory operatorSet,
        IStrategy strategy,
        bool isRedistributing
    ) internal {
        // We do not currently support redistributing beaconchain ETH or EIGEN.
        if (isRedistributing) {
            require(strategy != BEACONCHAIN_ETH_STRAT && strategy != eigenStrategy, InvalidStrategy());
        }

        require(_operatorSetStrategies[operatorSet.key()].add(address(strategy)), StrategyAlreadyInOperatorSet());
        emit StrategyAddedToOperatorSet(operatorSet, strategy);
    }

    /// @notice Creates a new operator set for an AVS.
    /// @param avs The AVS address that owns the operator set.
    /// @param params The parameters for creating the operator set.
    /// @param redistributionRecipient Address to receive redistributed funds when operators are slashed.
    /// @dev If `redistributionRecipient` is address(0), the operator set is considered non-redistributing
    /// and slashed funds are sent to the `DEFAULT_BURN_ADDRESS`.
    /// @dev Providing `BEACONCHAIN_ETH_STRAT` as a strategy will revert since it's not currently supported.
    /// @dev The address that can slash the operatorSet is the `avs` address.
    function _createOperatorSet(
        address avs,
        CreateSetParamsV2 memory params,
        address redistributionRecipient
    ) internal {
        OperatorSet memory operatorSet = OperatorSet(avs, params.operatorSetId);

        // Create the operator set, ensuring it does not already exist.
        require(_operatorSets[avs].add(operatorSet.id), InvalidOperatorSet());
        emit OperatorSetCreated(operatorSet);

        bool isRedistributing = redistributionRecipient != DEFAULT_BURN_ADDRESS;

        if (isRedistributing) {
            _redistributionRecipients[operatorSet.key()] = redistributionRecipient;
            emit RedistributionAddressSet(operatorSet, redistributionRecipient);
        }

        for (uint256 j = 0; j < params.strategies.length; j++) {
            _addStrategyToOperatorSet(operatorSet, params.strategies[j], isRedistributing);
        }

        // Update the slasher for the operator set
        _updateSlasher({operatorSet: operatorSet, slasher: params.slasher, instantEffectBlock: true});
    }

    /// @dev Clear one or more pending deallocations to a strategy's allocated magnitude
    /// @param operator the operator whose pending deallocations will be cleared
    /// @param strategy the strategy to update
    /// @param numToClear the number of pending deallocations to clear
    function _clearDeallocationQueue(
        address operator,
        IStrategy strategy,
        uint16 numToClear
    ) internal {
        uint256 numCleared;
        uint256 length = deallocationQueue[operator][strategy].length();

        while (length > 0 && numCleared < numToClear) {
            bytes32 operatorSetKey = deallocationQueue[operator][strategy].front();
            (StrategyInfo memory info, Allocation memory allocation) =
                _getUpdatedAllocation(operator, operatorSetKey, strategy);

            // If we've reached a pending deallocation that isn't completable yet,
            // we can stop. Any subsequent deallocation will also be uncompletable.
            if (block.number < allocation.effectBlock) {
                break;
            }

            // Update state. This completes the deallocation, because `_getUpdatedAllocation`
            // gave us strategy/allocation info as if the deallocation was already completed.
            _updateAllocationInfo(operator, operatorSetKey, strategy, info, allocation);

            // Remove the deallocation from the queue
            deallocationQueue[operator][strategy].popFront();
            ++numCleared;
            --length;
        }
    }

    /// @dev Sets the operator's allocation delay. This is the number of blocks between an operator
    /// allocating magnitude to an operator set, and the magnitude becoming slashable.
    /// @param operator The operator to set the delay on behalf of.
    /// @param delay The allocation delay in blocks.
    /// @param newlyRegistered Whether the operator is newly registered in the core protocol.
    function _setAllocationDelay(
        address operator,
        uint32 delay,
        bool newlyRegistered
    ) internal {
        AllocationDelayInfo memory info = _allocationDelayInfo[operator];

        // If there is a pending delay that can be applied now, set it
        if (info.effectBlock != 0 && block.number >= info.effectBlock) {
            info.delay = info.pendingDelay;
            info.isSet = true;
        }

        info.pendingDelay = delay;

        /// If the caller is the delegationManager, the operator is newly registered
        /// This results in *newly-registered* operators in the core protocol to have their allocation delay effective immediately
        if (newlyRegistered) {
            // The delay takes effect immediately
            info.effectBlock = uint32(block.number);
        } else {
            // Wait the entire configuration delay before the delay takes effect
            info.effectBlock = uint32(block.number) + ALLOCATION_CONFIGURATION_DELAY + 1;
        }

        _allocationDelayInfo[operator] = info;
        emit AllocationDelaySet(operator, delay, info.effectBlock);
    }

    /// @notice returns whether the operator's allocation is slashable in the given operator set
    function _isAllocationSlashable(
        OperatorSet memory operatorSet,
        IStrategy strategy,
        Allocation memory allocation,
        bool _isOperatorSlashable
    ) internal view returns (bool) {
        /// forgefmt: disable-next-item
        return 
            // If the operator set does not use this strategy, any allocation from it is not slashable
            _operatorSetStrategies[operatorSet.key()].contains(address(strategy)) &&
            // If the operator is not slashable by the operatorSet, any allocation is not slashable
            _isOperatorSlashable &&
            // If there is nothing allocated, the allocation is not slashable
            allocation.currentMagnitude != 0;
    }

    /// @dev For an operator set, get the operator's effective allocated magnitude.
    /// If the operator set has a pending deallocation that can be completed at the
    /// current block number, this method returns a view of the allocation as if the deallocation
    /// was completed.
    /// @return info the effective allocated and pending magnitude for the operator set, and
    /// the effective encumbered magnitude for all operator sets belonging to this strategy
    function _getUpdatedAllocation(
        address operator,
        bytes32 operatorSetKey,
        IStrategy strategy
    ) internal view returns (StrategyInfo memory, Allocation memory) {
        StrategyInfo memory info = StrategyInfo({
            maxMagnitude: _maxMagnitudeHistory[operator][strategy].latest(),
            encumberedMagnitude: encumberedMagnitude[operator][strategy]
        });

        Allocation memory allocation = allocations[operator][operatorSetKey][strategy];

        // If the pending change can't be completed yet, return as-is
        if (block.number < allocation.effectBlock) {
            return (info, allocation);
        }

        // Otherwise, complete the pending change and return updated info
        allocation.currentMagnitude = _addInt128(allocation.currentMagnitude, allocation.pendingDiff);

        // If the completed change was a deallocation, update used magnitude
        if (allocation.pendingDiff < 0) {
            info.encumberedMagnitude = _addInt128(info.encumberedMagnitude, allocation.pendingDiff);
        }

        allocation.effectBlock = 0;
        allocation.pendingDiff = 0;

        return (info, allocation);
    }

    function _updateAllocationInfo(
        address operator,
        bytes32 operatorSetKey,
        IStrategy strategy,
        StrategyInfo memory info,
        Allocation memory allocation
    ) internal {
        // Update encumbered magnitude if it has changed
        // The mapping should NOT be updated when there is a deallocation on a delay
        if (encumberedMagnitude[operator][strategy] != info.encumberedMagnitude) {
            encumberedMagnitude[operator][strategy] = info.encumberedMagnitude;
            emit EncumberedMagnitudeUpdated(operator, strategy, info.encumberedMagnitude);
        }

        // Update allocation for this operator set from the strategy
        // We emit an `AllocationUpdated` from the `modifyAllocations` and `slashOperator` functions.
        // `clearDeallocationQueue` does not emit an `AllocationUpdated` event since it was
        // emitted when the deallocation was queued
        allocations[operator][operatorSetKey][strategy] = allocation;

        // Note: these no-op if the sets already contain the added values (or do not contain removed ones)
        if (allocation.pendingDiff != 0) {
            // If we have a pending modification, ensure the allocation is in the operator's
            // list of enumerable strategies/sets.
            allocatedStrategies[operator][operatorSetKey].add(address(strategy));
            allocatedSets[operator].add(operatorSetKey);
        } else if (allocation.currentMagnitude == 0) {
            // If we do NOT have a pending modification, and no existing magnitude, remove the
            // allocation from the operator's lists.
            allocatedStrategies[operator][operatorSetKey].remove(address(strategy));

            if (allocatedStrategies[operator][operatorSetKey].length() == 0) {
                allocatedSets[operator].remove(operatorSetKey);
            }
        }
    }

    function _updateMaxMagnitude(
        address operator,
        IStrategy strategy,
        uint64 newMaxMagnitude
    ) internal {
        _maxMagnitudeHistory[operator][strategy].push({key: uint32(block.number), value: newMaxMagnitude});
        emit MaxMagnitudeUpdated(operator, strategy, newMaxMagnitude);
    }

    function _calcDelta(
        uint64 currentMagnitude,
        uint64 newMagnitude
    ) internal pure returns (int128) {
        return int128(uint128(newMagnitude)) - int128(uint128(currentMagnitude));
    }

    /// @dev Use safe casting when downcasting to uint64
    function _addInt128(
        uint64 a,
        int128 b
    ) internal pure returns (uint64) {
        return uint256(int256(int128(uint128(a)) + b)).toUint64();
    }

    /// @dev Helper function to update the slasher for an operator set
    /// @param operatorSet the operator set to update the slasher for
    /// @param slasher the new slasher
    /// @param instantEffectBlock Whether the new slasher will take effect immediately. Instant if on operatorSet creation or migration function.
    ///        The new slasher will take `ALLOCATION_CONFIGURATION_DELAY` blocks to take effect if called by the `updateSlasher` function.
    function _updateSlasher(
        OperatorSet memory operatorSet,
        address slasher,
        bool instantEffectBlock
    ) internal {
        // Ensure that the slasher address is not the 0 address, which is used to denote if the slasher is not set
        require(slasher != address(0), InputAddressZero());

        SlasherParams memory params = _slashers[operatorSet.key()];

        // If there is a pending slasher that can be applied, apply it
        if (params.effectBlock != 0 && block.number >= params.effectBlock) {
            params.slasher = params.pendingSlasher;
        }

        // Set the pending parameters
        params.pendingSlasher = slasher;
        if (instantEffectBlock) {
            params.effectBlock = uint32(block.number);
        } else {
            params.effectBlock = uint32(block.number) + ALLOCATION_CONFIGURATION_DELAY + 1;
        }

        _slashers[operatorSet.key()] = params;
        emit SlasherUpdated(operatorSet, slasher, params.effectBlock);
    }

    /// @notice Helper function to convert CreateSetParams to CreateSetParamsV2
    /// @param params The parameters to convert
    /// @param avs The AVS address that owns the operator sets, which will be the slasher
    /// @return The converted parameters, into CreateSetParamsV2 format
    /// @dev The slasher will be set to the AVS address
    function _convertCreateSetParams(
        CreateSetParams[] calldata params,
        address avs
    ) internal pure returns (CreateSetParamsV2[] memory) {
        CreateSetParamsV2[] memory createSetParams = new CreateSetParamsV2[](params.length);
        for (uint256 i = 0; i < params.length; i++) {
            createSetParams[i] = CreateSetParamsV2(params[i].operatorSetId, params[i].strategies, avs);
        }
        return createSetParams;
    }

    ///
    ///                         VIEW FUNCTIONS
    ///

    /// Public View Functions

    /// @inheritdoc IAllocationManagerView
    function getAVSRegistrar(
        address avs
    ) public view returns (IAVSRegistrar) {
        IAVSRegistrar registrar = _avsRegistrar[avs];
        // 如果 AVS 设置了自定义 Registrar，使用自定义的,AVS 通过 setAVSRegistrar() 设置独立合约
        // 否则，假设 AVS 地址本身实现了 IAVSRegistrar 接口
        return address(registrar) == address(0) ? IAVSRegistrar(avs) : registrar;
    }

    /// @inheritdoc IAllocationManagerView
    function isRedistributingOperatorSet(
        OperatorSet memory operatorSet
    ) public view returns (bool) {
        return getRedistributionRecipient(operatorSet) != DEFAULT_BURN_ADDRESS;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocationDelay(
        address operator
    ) public view returns (bool, uint32) {
        AllocationDelayInfo memory info = _allocationDelayInfo[operator];

        uint32 delay = info.delay;
        bool isSet = info.isSet;

        // If there is a pending delay that can be applied, apply it
        if (info.effectBlock != 0 && block.number >= info.effectBlock) {
            delay = info.pendingDelay;
            isSet = true;
        }

        return (isSet, delay);
    }

    /// @inheritdoc IAllocationManagerView
    function isOperatorSlashable(
        address operator,
        OperatorSet memory operatorSet
    ) public view returns (bool) {
        RegistrationStatus memory status = registrationStatus[operator][operatorSet.key()];

        // slashableUntil returns the last block the operator is slashable in so we check for
        // less than or equal to
        return status.registered || block.number <= status.slashableUntil;
    }

    /// @inheritdoc IAllocationManagerView
    function getRedistributionRecipient(
        OperatorSet memory operatorSet
    ) public view returns (address) {
        // Load the redistribution recipient and return it if set, otherwise return the default burn address.
        address redistributionRecipient = _redistributionRecipients[operatorSet.key()];
        return redistributionRecipient == address(0) ? DEFAULT_BURN_ADDRESS : redistributionRecipient;
    }

    /// @inheritdoc IAllocationManagerView
    function getSlasher(
        OperatorSet memory operatorSet
    ) public view returns (address) {
        SlasherParams memory params = _slashers[operatorSet.key()];

        address slasher = params.slasher;

        // If there is a pending slasher that can be applied, apply it
        if (params.effectBlock != 0 && block.number >= params.effectBlock) {
            slasher = params.pendingSlasher;
        }

        return slasher;
    }

    /// External View Functions
    /// These functions are delegated to the view implementation

    /// @inheritdoc IAllocationManagerView
    function getOperatorSetCount(
        address
    ) external view returns (uint256 count) {
        _delegateView(viewImplementation);
        count;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocatedSets(
        address
    ) external view returns (OperatorSet[] memory operatorSets) {
        _delegateView(viewImplementation);
        operatorSets;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocatedStrategies(
        address,
        OperatorSet memory
    ) external view returns (IStrategy[] memory strategies) {
        _delegateView(viewImplementation);
        strategies;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocation(
        address,
        OperatorSet memory,
        IStrategy
    ) external view returns (Allocation memory allocation) {
        _delegateView(viewImplementation);
        allocation;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocations(
        address[] memory,
        OperatorSet memory,
        IStrategy
    ) external view returns (Allocation[] memory allocations) {
        _delegateView(viewImplementation);
        allocations;
    }

    /// @inheritdoc IAllocationManagerView
    function getStrategyAllocations(
        address,
        IStrategy
    ) external view returns (OperatorSet[] memory operatorSets, Allocation[] memory allocations) {
        _delegateView(viewImplementation);
        operatorSets;
        allocations;
    }

    /// @inheritdoc IAllocationManagerView
    function getEncumberedMagnitude(
        address,
        IStrategy
    ) external view returns (uint64 encumberedMagnitude) {
        _delegateView(viewImplementation);
        encumberedMagnitude;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocatableMagnitude(
        address,
        IStrategy
    ) external view returns (uint64 allocatableMagnitude) {
        _delegateView(viewImplementation);
        allocatableMagnitude;
    }

    /// @inheritdoc IAllocationManagerView
    function getMaxMagnitude(
        address,
        IStrategy
    ) external view returns (uint64 maxMagnitude) {
        _delegateView(viewImplementation);
        maxMagnitude;
    }

    /// @inheritdoc IAllocationManagerView
    function getMaxMagnitudes(
        address,
        IStrategy[] calldata
    ) external view returns (uint64[] memory maxMagnitudes) {
        _delegateView(viewImplementation);
        maxMagnitudes;
    }

    /// @inheritdoc IAllocationManagerView
    function getMaxMagnitudes(
        address[] calldata,
        IStrategy
    ) external view returns (uint64[] memory maxMagnitudes) {
        _delegateView(viewImplementation);
        maxMagnitudes;
    }

    /// @inheritdoc IAllocationManagerView
    function getMaxMagnitudesAtBlock(
        address,
        IStrategy[] calldata,
        uint32
    ) external view returns (uint64[] memory maxMagnitudes) {
        _delegateView(viewImplementation);
        maxMagnitudes;
    }

    /// @inheritdoc IAllocationManagerView
    function getRegisteredSets(
        address
    ) external view returns (OperatorSet[] memory operatorSets) {
        _delegateView(viewImplementation);
        operatorSets;
    }

    /// @inheritdoc IAllocationManagerView
    function isMemberOfOperatorSet(
        address,
        OperatorSet memory
    ) external view returns (bool result) {
        _delegateView(viewImplementation);
        result;
    }

    /// @inheritdoc IAllocationManagerView
    function isOperatorSet(
        OperatorSet memory
    ) external view returns (bool result) {
        _delegateView(viewImplementation);
        result;
    }

    /// @inheritdoc IAllocationManagerView
    function getMembers(
        OperatorSet memory
    ) external view returns (address[] memory operators) {
        _delegateView(viewImplementation);
        operators;
    }

    /// @inheritdoc IAllocationManagerView
    function getMemberCount(
        OperatorSet memory
    ) external view returns (uint256 memberCount) {
        _delegateView(viewImplementation);
        memberCount;
    }

    /// @inheritdoc IAllocationManagerView
    function getStrategiesInOperatorSet(
        OperatorSet memory
    ) external view returns (IStrategy[] memory strategies) {
        _delegateView(viewImplementation);
        strategies;
    }

    /// @inheritdoc IAllocationManagerView
    function getMinimumSlashableStake(
        OperatorSet memory,
        address[] memory,
        IStrategy[] memory,
        uint32
    ) external view returns (uint256[][] memory slashableStake) {
        _delegateView(viewImplementation);
        slashableStake;
    }

    /// @inheritdoc IAllocationManagerView
    function getAllocatedStake(
        OperatorSet memory,
        address[] memory,
        IStrategy[] memory
    ) external view returns (uint256[][] memory slashableStake) {
        _delegateView(viewImplementation);
        slashableStake;
    }

    /// @inheritdoc IAllocationManagerView
    function getPendingSlasher(
        OperatorSet memory
    ) external view returns (address pendingSlasher, uint32 effectBlock) {
        _delegateView(viewImplementation);
        pendingSlasher;
        effectBlock;
    }

    /// @inheritdoc IAllocationManagerView
    function getSlashCount(
        OperatorSet memory
    ) external view returns (uint256 slashCount) {
        _delegateView(viewImplementation);
        slashCount;
    }

    /// @inheritdoc IAllocationManagerView
    function isOperatorRedistributable(
        address
    ) external view returns (bool result) {
        _delegateView(viewImplementation);
        result;
    }
}

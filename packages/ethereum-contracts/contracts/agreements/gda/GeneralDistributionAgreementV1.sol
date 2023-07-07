// SPDX-License-Identifier: AGPLv3
pragma solidity 0.8.19;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {
    ISuperfluid,
    ISuperfluidGovernance,
    SuperfluidGovernanceConfigs
} from "../../interfaces/superfluid/ISuperfluid.sol";
import "@superfluid-finance/solidity-semantic-money/src/SemanticMoney.sol";
import { TokenMonad } from "@superfluid-finance/solidity-semantic-money/src/TokenMonad.sol";
import { SuperfluidPool } from "../../superfluid/SuperfluidPool.sol";
import { SuperfluidPoolDeployerLibrary } from "../../libs/SuperfluidPoolDeployerLibrary.sol";
import { IGeneralDistributionAgreementV1 } from "../../interfaces/agreements/IGeneralDistributionAgreementV1.sol";
import { ISuperfluidToken } from "../../interfaces/superfluid/ISuperfluidToken.sol";
import { IConstantOutflowNFT } from "../../interfaces/superfluid/IConstantOutflowNFT.sol";
import { ISuperToken } from "../../interfaces/superfluid/ISuperToken.sol";
import { IPoolAdminNFT } from "../../interfaces/superfluid/IPoolAdminNFT.sol";
import { ISuperfluidPool } from "../../interfaces/superfluid/ISuperfluidPool.sol";
import { SlotsBitmapLibrary } from "../../libs/SlotsBitmapLibrary.sol";
import { SafeGasLibrary } from "../../libs/SafeGasLibrary.sol";
import { AgreementBase } from "../AgreementBase.sol";
import { AgreementLibrary } from "../AgreementLibrary.sol";
import {
    UniversalIndexData, FlowDistributionData, PoolMemberData, _StackVars_Liquidation
} from "./static/Structs.sol";
import { GeneralDistributionAgreementUtils } from "./GeneralDistributionAgreementUtils.sol";

// TODO: add summed CFA + GDA net flow rate onto SuperToken.sol/SuperfluidToken.sol

/**
 * @title General Distribution Agreement
 * @author Superfluid
 * @notice
 *
 * Storage Layout Notes
 * Agreement State
 *
 * Universal Index Data
 * slotId           = _UNIVERSAL_INDEX_STATE_SLOT_ID or 0
 * msg.sender       = address of GDAv1
 * account          = context.msgSender
 * Universal Index Data stores a Basic Particle for an account as well as the total buffer and
 * whether the account is a pool or not.
 *
 * SlotsBitmap Data
 * slotId           = _POOL_SUBS_BITMAP_STATE_SLOT_ID or 1
 * msg.sender       = address of GDAv1
 * account          = context.msgSender
 * Slots Bitmap Data Slot stores a bitmap of the slots that are "enabled" for a pool member.
 *
 * Pool Connections Data Slot Id Start
 * slotId (start)   = _POOL_CONNECTIONS_DATA_STATE_SLOT_ID_START or 1 << 128 or 340282366920938463463374607431768211456
 * msg.sender       = address of GDAv1
 * account          = context.msgSender
 * Pool Connections Data Slot Id Start indicates the starting slot for where we begin to store the pools that a
 * pool member is a part of.
 *
 *
 * Agreement Data
 * NOTE The Agreement Data slot is calculated with the following function:
 * keccak256(abi.encode("AgreementData", agreementClass, agreementId))
 * agreementClass       = address of GDAv1
 * agreementId          = DistributionFlowId | PoolMemberId
 *
 * DistributionFlowId   =
 * keccak256(abi.encode(block.chainid, "distributionFlow", from, pool))
 * DistributionFlowId stores FlowDistributionData between a sender (from) and pool.
 *
 * PoolMemberId         =
 * keccak256(abi.encode(block.chainid, "poolMember", member, pool))
 * PoolMemberId stores PoolMemberData for a member at a pool.
 */
contract GeneralDistributionAgreementV1 is
    AgreementBase,
    TokenMonad,
    IGeneralDistributionAgreementV1,
    GeneralDistributionAgreementUtils
{
    using SafeCast for uint256;
    using SafeCast for int256;
    using SemanticMoney for BasicParticle;

    address public constant SLOTS_BITMAP_LIBRARY_ADDRESS = address(SlotsBitmapLibrary);

    address public constant SUPERFLUID_POOL_DEPLOYER_ADDRESS = address(SuperfluidPoolDeployerLibrary);

    IBeacon public superfluidPoolBeacon;

    constructor(ISuperfluid host) AgreementBase(address(host)) { }

    function initialize(IBeacon superfluidPoolBeacon_) external initializer {
        superfluidPoolBeacon = superfluidPoolBeacon_;
    }

    /// @dev ISuperAgreement.realtimeBalanceOf implementation
    function realtimeBalanceOfNow(ISuperfluidToken token, address account)
        external
        view
        returns (int256 availableBalance, uint256 buffer, uint256 owedBuffer, uint256 timestamp)
    {
        (availableBalance, buffer, owedBuffer) = realtimeBalanceOf(token, account, block.timestamp);
        timestamp = block.timestamp;
    }

    function realtimeBalanceOf(ISuperfluidToken token, address account, uint256 time)
        public
        view
        override
        returns (int256 realtimeBalance, uint256 buffer, uint256 owedBuffer)
    {
        (int256 availableBalance, int256 fromPools, int256 buf) = realtimeBalanceVectorAt(token, account, time);
        realtimeBalance = availableBalance + fromPools - buf;

        buffer = uint256(buf); // upcasting to uint256 is safe
        owedBuffer = 0;
    }

    function realtimeBalanceVectorAt(ISuperfluidToken token, address account, uint256 time)
        public
        view
        returns (int256 own, int256 fromPools, int256 buffer)
    {
        UniversalIndexData memory universalIndexData = _getUIndexData(abi.encode(token), account);
        BasicParticle memory uIndexParticle = _getBasicParticleFromUIndex(universalIndexData);

        uint32 timeu32 = uint32(time);
        if (_isPool(token, account)) {
            own = ISuperfluidPool(account).getDisconnectedBalance(timeu32);
        } else {
            own = Value.unwrap(uIndexParticle.rtb(Time.wrap(timeu32)));
        }

        fromPools = _getBalanceFromPools(token, account, timeu32);

        buffer = universalIndexData.totalBuffer.toInt256();
    }

    function _getBalanceFromPools(ISuperfluidToken token, address account, uint32 time)
        internal
        view
        returns (int256 fromPools)
    {
        (uint32[] memory slotIds, bytes32[] memory pidList) = _listPoolConnectionIds(token, account);
        for (uint256 i = 0; i < slotIds.length; ++i) {
            address pool = address(uint160(uint256(pidList[i])));
            (bool exist, PoolMemberData memory poolMemberData) =
                _getPoolMemberData(token, account, ISuperfluidPool(pool));
            // TODO: Do we need these asserts here? Potentially remove.
            assert(exist);
            assert(poolMemberData.pool == pool);
            fromPools = fromPools + ISuperfluidPool(pool).getClaimable(account, time);
        }
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function getNetFlow(ISuperfluidToken token, address account) external view override returns (int96 netFlowRate) {
        netFlowRate = int256(FlowRate.unwrap(_getUIndex(abi.encode(token), account).flow_rate())).toInt96();

        if (_isPool(token, account)) {
            netFlowRate += ISuperfluidPool(account).getTotalDisconnectedFlowRate();
        }

        {
            (uint32[] memory slotIds, bytes32[] memory pidList) = _listPoolConnectionIds(token, account);
            for (uint256 i = 0; i < slotIds.length; ++i) {
                ISuperfluidPool pool = ISuperfluidPool(address(uint160(uint256(pidList[i]))));
                netFlowRate += pool.getMemberFlowRate(account);
            }
        }
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function getFlowRate(ISuperfluidToken token, address from, ISuperfluidPool to)
        external
        view
        override
        returns (int96 flowRate)
    {
        bytes32 distributionFlowHash = _getFlowDistributionHash(from, to);
        (, FlowDistributionData memory data) = _getFlowDistributionData(token, distributionFlowHash);
        flowRate = data.flowRate;
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function estimateFlowDistributionActualFlowRate(
        ISuperfluidToken token,
        address from,
        ISuperfluidPool to,
        int96 requestedFlowRate
    ) external view override returns (int96 actualFlowRate, int96 totalDistributionFlowRate) {
        // TODO: Consider renaming eff to encodedToken?, eff is ambigous
        bytes memory eff = abi.encode(token);
        bytes32 distributionFlowHash = _getFlowDistributionHash(from, to);

        BasicParticle memory fromUIndexData = _getUIndex(eff, from);

        PDPoolIndex memory pdpIndex = _getPDPIndex("", address(to));

        FlowRate oldFlowRate = _getFlowRate(eff, distributionFlowHash);
        FlowRate newActualFlowRate;
        FlowRate oldDistributionFlowRate = pdpIndex.flow_rate();
        FlowRate newDistributionFlowRate;
        FlowRate flowRateDelta = FlowRate.wrap(requestedFlowRate) - oldFlowRate;
        FlowRate currentAdjustmentFlowRate = _getPoolAdjustmentFlowRate(eff, address(to));

        Time t = Time.wrap(uint32(block.timestamp));
        (fromUIndexData, pdpIndex, newDistributionFlowRate) =
            fromUIndexData.shift_flow2b(pdpIndex, flowRateDelta + currentAdjustmentFlowRate, t);
        newActualFlowRate =
            oldFlowRate + (newDistributionFlowRate - oldDistributionFlowRate) - currentAdjustmentFlowRate;
        actualFlowRate = int256(FlowRate.unwrap(newActualFlowRate)).toInt96();
        totalDistributionFlowRate = int256(FlowRate.unwrap(newDistributionFlowRate)).toInt96();
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function estimateDistributionActualAmount(
        ISuperfluidToken token,
        address from,
        ISuperfluidPool to,
        uint256 requestedAmount
    ) external view override returns (uint256 actualAmount) {
        bytes memory eff = abi.encode(token);
        BasicParticle memory fromUIndexData = _getUIndex(eff, from);

        PDPoolIndex memory pdpIndex = _getPDPIndex("", address(to));
        Value actualDistributionAmount;
        (fromUIndexData, pdpIndex, actualDistributionAmount) =
            fromUIndexData.shift2b(pdpIndex, Value.wrap(requestedAmount.toInt256()));

        actualAmount = uint256(Value.unwrap(actualDistributionAmount));
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function createPool(ISuperfluidToken token, address admin) external override returns (ISuperfluidPool pool) {
        if (admin == address(0)) revert GDA_NO_ZERO_ADDRESS_ADMIN();

        pool =
            ISuperfluidPool(address(SuperfluidPoolDeployerLibrary.deploy(address(superfluidPoolBeacon), admin, token)));

        // @note We utilize the storage slot for Universal Index State
        // to store whether an account is a pool or not
        bytes32[] memory data = new bytes32[](1);
        data[0] = bytes32(uint256(1));
        token.updateAgreementStateSlot(address(pool), _UNIVERSAL_INDEX_STATE_SLOT_ID, data);

        IPoolAdminNFT poolAdminNFT = IPoolAdminNFT(_canCallPoolAdminNFTHook(token));

        uint256 gasLeftBefore = gasleft();
        try poolAdminNFT.mint(address(pool)) {
            // solhint-disable-next-line no-empty-blocks
        } catch {
            SafeGasLibrary._revertWhenOutOfGas(gasLeftBefore);
        }

        emit PoolCreated(token, admin, pool);
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function connectPool(ISuperfluidPool pool, bytes calldata ctx) external override returns (bytes memory newCtx) {
        return connectPool(pool, true, ctx);
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function disconnectPool(ISuperfluidPool pool, bytes calldata ctx) external override returns (bytes memory newCtx) {
        return connectPool(pool, false, ctx);
    }

    function connectPool(ISuperfluidPool pool, bool doConnect, bytes calldata ctx)
        public
        returns (bytes memory newCtx)
    {
        ISuperfluidToken token = pool.superToken();
        ISuperfluid.Context memory currentContext = AgreementLibrary.authorizeTokenAccess(token, ctx);
        address msgSender = currentContext.msgSender;
        newCtx = ctx;
        if (doConnect) {
            _tryConnectMemberToPool(pool, token, msgSender);
        } else {
            _tryDisconnectMemberFromPool(pool, token, msgSender);
        }

        emit PoolConnectionUpdated(token, pool, msgSender, doConnect);
    }

    function _tryConnectMemberToPool(ISuperfluidPool pool, ISuperfluidToken token, address msgSender) internal {
        if (!isMemberConnected(token, address(pool), msgSender)) {
            // TODO: Remove assert and add try/catch + revert
            assert(SuperfluidPool(address(pool)).operatorConnectMember(msgSender, true, uint32(block.timestamp)));
            uint32 poolSlotID =
                _findAndFillPoolConnectionsBitmap(token, msgSender, bytes32(uint256(uint160(address(pool)))));

            token.createAgreement(
                _getPoolMemberHash(msgSender, pool),
                _encodePoolMemberData(PoolMemberData({ poolID: poolSlotID, pool: address(pool) }))
            );
        }
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function isMemberConnected(ISuperfluidToken token, address pool, address member)
        public
        view
        override
        returns (bool)
    {
        (bool exist,) = _getPoolMemberData(token, member, ISuperfluidPool(pool));
        return exist;
    }

    function isMemberConnected(ISuperfluidPool pool, address member) public view override returns (bool) {
        ISuperfluidToken token = pool.superToken();
        return isMemberConnected(token, address(pool), member);
    }

    function _tryDisconnectMemberFromPool(ISuperfluidPool pool, ISuperfluidToken token, address msgSender) internal {
        if (isMemberConnected(token, address(pool), msgSender)) {
            // TODO: Remove assert and add try/catch + revert
            assert(SuperfluidPool(address(pool)).operatorConnectMember(msgSender, false, uint32(block.timestamp)));
            (, PoolMemberData memory poolMemberData) = _getPoolMemberData(token, msgSender, pool);
            token.terminateAgreement(_getPoolMemberHash(msgSender, pool), 1);

            _clearPoolConnectionsBitmap(token, msgSender, poolMemberData.poolID);
        }
    }

    function appendIndexUpdateByPool(ISuperfluidToken token, BasicParticle memory p, Time t) external returns (bool) {
        _appendIndexUpdateByPool(abi.encode(token), msg.sender, p, t);
        return true;
    }

    function _appendIndexUpdateByPool(bytes memory eff, address pool, BasicParticle memory p, Time t) internal {
        address token = abi.decode(eff, (address));
        if (_isPool(ISuperfluidToken(token), msg.sender) == false) {
            revert GDA_ONLY_SUPER_TOKEN_POOL();
        }

        _setUIndex(eff, pool, _getUIndex(eff, pool).mappend(p));
        _setPoolAdjustmentFlowRate(eff, pool, true, /* doShift? */ p.flow_rate(), t);
    }

    function poolSettleClaim(ISuperfluidToken superToken, address claimRecipient, int256 amount)
        external
        returns (bool)
    {
        bytes memory eff = abi.encode(superToken);
        _poolSettleClaim(eff, claimRecipient, Value.wrap(amount));
        return true;
    }

    function _poolSettleClaim(bytes memory eff, address claimRecipient, Value amount) internal {
        address token = abi.decode(eff, (address));
        if (_isPool(ISuperfluidToken(token), msg.sender) == false) {
            revert GDA_ONLY_SUPER_TOKEN_POOL();
        }
        _doShift(eff, msg.sender, claimRecipient, amount);
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function distribute(
        ISuperfluidToken token,
        address from,
        ISuperfluidPool pool,
        uint256 requestedAmount,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        ISuperfluid.Context memory currentContext = AgreementLibrary.authorizeTokenAccess(token, ctx);

        newCtx = ctx;

        if (_isPool(token, address(pool)) == false) {
            revert GDA_ONLY_SUPER_TOKEN_POOL();
        }

        if (from != currentContext.msgSender) {
            revert GDA_DISTRIBUTE_FOR_OTHERS_NOT_ALLOWED();
        }

        (, Value actualAmount) = _doDistributeViaPool(
            abi.encode(token), currentContext.msgSender, address(pool), Value.wrap(requestedAmount.toInt256())
        );

        if (token.isAccountCriticalNow(from)) {
            revert GDA_INSUFFICIENT_BALANCE();
        }

        // TODO: tokens are moving from sender => pool, including a transfer event makes sense here
        // trigger from the supertoken contract

        emit InstantDistributionUpdated(
            token,
            pool,
            from,
            currentContext.msgSender,
            requestedAmount,
            uint256(Value.unwrap(actualAmount)) // upcast from int256 -> uint256 is safe
        );
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function distributeFlow(
        ISuperfluidToken token,
        address from,
        ISuperfluidPool pool,
        int96 requestedFlowRate,
        bytes calldata ctx
    ) external override returns (bytes memory newCtx) {
        if (_isPool(token, address(pool)) == false) {
            revert GDA_ONLY_SUPER_TOKEN_POOL();
        }
        if (requestedFlowRate < 0) {
            revert GDA_NO_NEGATIVE_FLOW_RATE();
        }

        ISuperfluid.Context memory currentContext = AgreementLibrary.authorizeTokenAccess(token, ctx);

        newCtx = ctx;

        bytes32 distributionFlowHash = _getFlowDistributionHash(from, pool);
        FlowRate oldFlowRate = _getFlowRate(abi.encode(token), distributionFlowHash);

        (, FlowRate actualFlowRate, FlowRate newDistributionFlowRate) = _doDistributeFlowViaPool(
            abi.encode(token),
            from,
            address(pool),
            distributionFlowHash,
            FlowRate.wrap(requestedFlowRate),
            Time.wrap(uint32(block.timestamp))
        );

        // handle distribute flow on behalf of someone else
        _handleDistributeFlowNotMsgSender(currentContext, token, from, requestedFlowRate, distributionFlowHash);

        _adjustBuffer(abi.encode(token), address(pool), from, distributionFlowHash, oldFlowRate, actualFlowRate);

        // ensure sender has enough balance to execute transaction
        _checkIfSenderHasEnoughBalance(currentContext, token, from, requestedFlowRate);

        // mint/burn FlowNFT to flow distributor
        _handleFlowDistributorNft(token, from, pool, requestedFlowRate, oldFlowRate);

        (address adjustmentFlowRecipient,, int96 adjustmentFlowRate) =
            _getPoolAdjustmentFlowInfo(abi.encode(token), address(pool));

        emit FlowDistributionUpdated(
            token,
            pool,
            from,
            currentContext.msgSender,
            int256(FlowRate.unwrap(oldFlowRate)).toInt96(),
            int256(FlowRate.unwrap(actualFlowRate)).toInt96(),
            int256(FlowRate.unwrap(newDistributionFlowRate)).toInt96(),
            adjustmentFlowRecipient,
            adjustmentFlowRate
        );
    }

    function _handleDistributeFlowNotMsgSender(
        ISuperfluid.Context memory ctx,
        ISuperfluidToken token,
        address from,
        int96 requestedFlowRate,
        bytes32 distributionFlowHash
    ) internal {
        if (from != ctx.msgSender) {
            if (requestedFlowRate > 0) {
                // @note no ACL support for now
                // revert if trying to distribute on behalf of others
                revert GDA_DISTRIBUTE_FOR_OTHERS_NOT_ALLOWED();
            } else {
                // liquidation case, requestedFlowRate == 0
                (int256 availableBalance,,) = token.realtimeBalanceOf(from, ctx.timestamp);
                // _StackVars_Liquidation used to handle good ol' stack too deep
                _StackVars_Liquidation memory liquidationData;
                {
                    // @note it would be nice to have oldflowRate returned from _doDistributeFlow
                    UniversalIndexData memory fromUIndexData = _getUIndexData(abi.encode(token), from);
                    liquidationData.token = token;
                    liquidationData.sender = from;
                    liquidationData.liquidator = ctx.msgSender;
                    liquidationData.distributionFlowHash = distributionFlowHash;
                    liquidationData.signedTotalGDADeposit = fromUIndexData.totalBuffer.toInt256();
                    liquidationData.availableBalance = availableBalance;
                }
                // closing stream on behalf of someone else: liquidation case
                if (availableBalance < 0) {
                    _makeLiquidationPayouts(liquidationData);
                } else {
                    revert GDA_NON_CRITICAL_SENDER();
                }
            }
        }
    }

    function _makeLiquidationPayouts(_StackVars_Liquidation memory data) internal {
        (, FlowDistributionData memory flowDistributionData) =
            _getFlowDistributionData(ISuperfluidToken(data.token), data.distributionFlowHash);
        int256 signedSingleDeposit = flowDistributionData.buffer.toInt256();

        bytes memory liquidationTypeData;
        bool isCurrentlyPatricianPeriod;

        {
            (uint256 liquidationPeriod, uint256 patricianPeriod) = _decode3PsData(data.token);
            isCurrentlyPatricianPeriod = _isPatricianPeriod(
                data.availableBalance, data.signedTotalGDADeposit, liquidationPeriod, patricianPeriod
            );
        }

        int256 totalRewardLeft = data.availableBalance + data.signedTotalGDADeposit;

        // critical case
        if (totalRewardLeft >= 0) {
            int256 rewardAmount = (signedSingleDeposit * totalRewardLeft) / data.signedTotalGDADeposit;
            liquidationTypeData = abi.encode(1, isCurrentlyPatricianPeriod ? 0 : 1);
            data.token.makeLiquidationPayoutsV2(
                data.distributionFlowHash,
                liquidationTypeData,
                data.liquidator,
                isCurrentlyPatricianPeriod,
                data.sender,
                rewardAmount.toUint256(),
                rewardAmount * -1
            );
        } else {
            int256 rewardAmount = signedSingleDeposit;
            // bailout case
            data.token.makeLiquidationPayoutsV2(
                data.distributionFlowHash,
                abi.encode(1, 2),
                data.liquidator,
                false,
                data.sender,
                rewardAmount.toUint256(),
                totalRewardLeft * -1
            );
        }
    }

    function _checkIfSenderHasEnoughBalance(
        ISuperfluid.Context memory ctx,
        ISuperfluidToken token,
        address from,
        int96 requestedFlowRate
    ) internal {
        // ensure sender has enough balance to execute transaction
        if (from == ctx.msgSender) {
            (int256 availableBalance,,) = token.realtimeBalanceOf(from, ctx.timestamp);
            // if from == msg.sender
            if (requestedFlowRate > 0 && availableBalance < 0) {
                revert GDA_INSUFFICIENT_BALANCE();
            }
        }
    }

    function _handleFlowDistributorNft(
        ISuperfluidToken token,
        address from,
        ISuperfluidPool pool,
        int96 requestedFlowRate,
        FlowRate oldFlowRate
    ) internal {
        address constantOutflowNFTAddress = _canCallConstantOutflowNFTHook(token);

        if (constantOutflowNFTAddress != address(0)) {
            uint256 gasLeftBefore;
            // create flow (mint)
            if (requestedFlowRate > 0 && FlowRate.unwrap(oldFlowRate) == 0) {
                gasLeftBefore = gasleft();
                try IConstantOutflowNFT(constantOutflowNFTAddress).onCreate(token, from, address(pool)) {
                    // solhint-disable-next-line no-empty-blocks
                } catch {
                    SafeGasLibrary._revertWhenOutOfGas(gasLeftBefore);
                }
            }

            // update flow (update metadata)
            if (requestedFlowRate > 0 && FlowRate.unwrap(oldFlowRate) > 0) {
                gasLeftBefore = gasleft();
                try IConstantOutflowNFT(constantOutflowNFTAddress).onUpdate(token, from, address(pool)) {
                    // solhint-disable-next-line no-empty-blocks
                } catch {
                    SafeGasLibrary._revertWhenOutOfGas(gasLeftBefore);
                }
            }

            // delete flow (burn)
            if (requestedFlowRate == 0) {
                gasLeftBefore = gasleft();
                try IConstantOutflowNFT(constantOutflowNFTAddress).onDelete(token, from, address(pool)) {
                    // solhint-disable-next-line no-empty-blocks
                } catch {
                    SafeGasLibrary._revertWhenOutOfGas(gasLeftBefore);
                }
            }
        }
    }

    /**
     * @notice Checks whether or not the NFT hook can be called.
     * @dev A staticcall, so `CONSTANT_OUTFLOW_NFT` must be a view otherwise the assumption is that it reverts
     * @param token the super token that is being streamed
     * @return constantOutflowNFTAddress the address returned by low level call
     */
    function _canCallConstantOutflowNFTHook(ISuperfluidToken token)
        internal
        view
        returns (address constantOutflowNFTAddress)
    {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) =
            address(token).staticcall(abi.encodeWithSelector(ISuperToken.CONSTANT_OUTFLOW_NFT.selector));

        if (success) {
            // @note We are aware this may revert if a Custom SuperToken's
            // CONSTANT_OUTFLOW_NFT does not return data that can be
            // decoded to an address. This would mean it was intentionally
            // done by the creator of the Custom SuperToken logic and is
            // fully expected to revert in that case as the author desired.
            constantOutflowNFTAddress = abi.decode(data, (address));
        }
    }

    function _canCallPoolAdminNFTHook(ISuperfluidToken token) internal view returns (address poolAdminNFTAddress) {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory data) =
            address(token).staticcall(abi.encodeWithSelector(ISuperToken.POOL_ADMIN_NFT.selector));

        if (success) {
            // @note We are aware this may revert if a Custom SuperToken's
            // POOL_ADMIN_NFT does not return data that can be
            // decoded to an address. This would mean it was intentionally
            // done by the creator of the Custom SuperToken logic and is
            // fully expected to revert in that case as the author desired.
            poolAdminNFTAddress = abi.decode(data, (address));
        }
    }

    function _adjustBuffer(
        bytes memory eff,
        address pool,
        address from,
        bytes32 flowHash,
        FlowRate, // oldFlowRate,
        FlowRate newFlowRate
    ) internal returns (bytes memory) {
        address token = abi.decode(eff, (address));
        // not using oldFlowRate in this model
        // surprising effect: reducing flow rate may require more buffer when liquidation_period adjusted upward
        ISuperfluidGovernance gov = ISuperfluidGovernance(ISuperfluid(_host).getGovernance());
        uint256 minimumDeposit =
            gov.getConfigAsUint256(ISuperfluid(msg.sender), ISuperfluidToken(token), SUPERTOKEN_MINIMUM_DEPOSIT_KEY);

        (uint256 liquidationPeriod,) = _decode3PsData(ISuperfluidToken(token));

        (, FlowDistributionData memory flowDistributionData) =
            _getFlowDistributionData(ISuperfluidToken(token), flowHash);

        // @note downcasting from uint256 -> uint32 for liquidation period
        Value newBufferAmount = newFlowRate.mul(Time.wrap(uint32(liquidationPeriod)));

        if (Value.unwrap(newBufferAmount).toUint256() < minimumDeposit && FlowRate.unwrap(newFlowRate) > 0) {
            newBufferAmount = Value.wrap(minimumDeposit.toInt256());
        }

        Value bufferDelta = newBufferAmount - Value.wrap(uint256(flowDistributionData.buffer).toInt256());

        eff = _doShift(eff, from, address(this), bufferDelta);

        {
            bytes32[] memory data = _encodeFlowDistributionData(
                FlowDistributionData({
                    lastUpdated: uint32(block.timestamp),
                    flowRate: int256(FlowRate.unwrap(newFlowRate)).toInt96(),
                    buffer: uint256(Value.unwrap(newBufferAmount)) // upcast to uint256 is safe
                 })
            );

            ISuperfluidToken(token).updateAgreementData(flowHash, data);
        }

        UniversalIndexData memory universalIndexData = _getUIndexData(eff, from);
        universalIndexData.totalBuffer =
        // new buffer
         (universalIndexData.totalBuffer.toInt256() + Value.unwrap(bufferDelta)).toUint256();
        ISuperfluidToken(token).updateAgreementStateSlot(
            from, _UNIVERSAL_INDEX_STATE_SLOT_ID, _encodeUniversalIndexData(universalIndexData)
        );
        universalIndexData = _getUIndexData(eff, from);

        {
            emit BufferAdjusted(
                ISuperfluidToken(token),
                ISuperfluidPool(pool),
                from,
                Value.unwrap(bufferDelta),
                Value.unwrap(newBufferAmount).toUint256(),
                universalIndexData.totalBuffer
            );
        }

        return eff;
    }

    // Solvency Related Getters
    function _decode3PsData(ISuperfluidToken token)
        internal
        view
        returns (uint256 liquidationPeriod, uint256 patricianPeriod)
    {
        ISuperfluidGovernance gov = ISuperfluidGovernance(ISuperfluid(_host).getGovernance());
        uint256 pppConfig = gov.getConfigAsUint256(ISuperfluid(_host), token, CFAV1_PPP_CONFIG_KEY);
        (liquidationPeriod, patricianPeriod) = SuperfluidGovernanceConfigs.decodePPPConfig(pppConfig);
    }

    function isPatricianPeriodNow(ISuperfluidToken token, address account)
        external
        view
        override
        returns (bool isCurrentlyPatricianPeriod, uint256 timestamp)
    {
        timestamp = ISuperfluid(_host).getNow();
        isCurrentlyPatricianPeriod = isPatricianPeriod(token, account, timestamp);
    }

    function isPatricianPeriod(ISuperfluidToken token, address account, uint256 timestamp)
        public
        view
        override
        returns (bool)
    {
        (int256 availableBalance,,) = token.realtimeBalanceOf(account, timestamp);
        if (availableBalance >= 0) {
            return true;
        }

        (uint256 liquidationPeriod, uint256 patricianPeriod) = _decode3PsData(token);
        UniversalIndexData memory uIndexData = _getUIndexData(abi.encode(token), account);

        return
            _isPatricianPeriod(availableBalance, uIndexData.totalBuffer.toInt256(), liquidationPeriod, patricianPeriod);
    }

    function _isPatricianPeriod(
        int256 availableBalance,
        int256 signedTotalGDADeposit,
        uint256 liquidationPeriod,
        uint256 patricianPeriod
    ) internal pure returns (bool) {
        if (signedTotalGDADeposit == 0) {
            return false;
        }

        int256 totalRewardLeft = availableBalance + signedTotalGDADeposit;
        int256 totalGDAOutFlowrate = signedTotalGDADeposit / liquidationPeriod.toInt256();
        // divisor cannot be zero with existing outflow
        return totalRewardLeft / totalGDAOutFlowrate > (liquidationPeriod - patricianPeriod).toInt256();
    }

    // TokenMonad virtual functions
    function _getUIndex(bytes memory eff, address owner) internal view override returns (BasicParticle memory uIndex) {
        address token = abi.decode(eff, (address));
        bytes32[] memory data =
            ISuperfluidToken(token).getAgreementStateSlot(address(this), owner, _UNIVERSAL_INDEX_STATE_SLOT_ID, 2);
        (, UniversalIndexData memory universalIndexData) = _decodeUniversalIndexData(data);
        uIndex = _getBasicParticleFromUIndex(universalIndexData);
    }

    function _setUIndex(bytes memory eff, address owner, BasicParticle memory p)
        internal
        override
        returns (bytes memory)
    {
        address token = abi.decode(eff, (address));
        // TODO see if this can be optimized, seems unnecessary to re-retrieve all the data
        // from storage to ensure totalBuffer and isPool isn't overriden
        UniversalIndexData memory universalIndexData = _getUIndexData(eff, owner);

        ISuperfluidToken(token).updateAgreementStateSlot(
            owner,
            _UNIVERSAL_INDEX_STATE_SLOT_ID,
            _encodeUniversalIndexData(p, universalIndexData.totalBuffer, universalIndexData.isPool)
        );

        return eff;
    }

    function _getPDPIndex(
        bytes memory, // eff,
        address pool
    ) internal view override returns (PDPoolIndex memory) {
        SuperfluidPool.PoolIndexData memory data = SuperfluidPool(pool).getIndex();
        return SuperfluidPool(pool).poolIndexDataToPDPoolIndex(data);
    }

    function _setPDPIndex(bytes memory eff, address pool, PDPoolIndex memory p)
        internal
        override
        returns (bytes memory)
    {
        assert(SuperfluidPool(pool).operatorSetIndex(p));

        return eff;
    }

    function _getFlowRate(bytes memory eff, bytes32 distributionFlowHash) internal view override returns (FlowRate) {
        address token = abi.decode(eff, (address));
        (, FlowDistributionData memory data) = _getFlowDistributionData(ISuperfluidToken(token), distributionFlowHash);
        return FlowRate.wrap(data.flowRate);
    }

    function _setFlowInfo(
        bytes memory eff,
        bytes32 flowHash,
        address, // from,
        address, // to,
        FlowRate newFlowRate,
        FlowRate // flowRateDelta
    ) internal override returns (bytes memory) {
        address token = abi.decode(eff, (address));
        (, FlowDistributionData memory flowDistributionData) =
            _getFlowDistributionData(ISuperfluidToken(token), flowHash);

        bytes32[] memory data = _encodeFlowDistributionData(
            FlowDistributionData({
                lastUpdated: uint32(block.timestamp),
                flowRate: int256(FlowRate.unwrap(newFlowRate)).toInt96(),
                buffer: flowDistributionData.buffer
            })
        );

        ISuperfluidToken(token).updateAgreementData(flowHash, data);

        return eff;
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function getPoolAdjustmentFlowInfo(ISuperfluidPool pool)
        external
        view
        override
        returns (address recipient, bytes32 flowHash, int96 flowRate)
    {
        bytes memory eff = abi.encode(pool.superToken());
        return _getPoolAdjustmentFlowInfo(eff, address(pool));
    }

    function _getPoolAdjustmentFlowInfo(bytes memory eff, address pool)
        internal
        view
        returns (address adjustmentRecipient, bytes32 flowHash, int96 flowRate)
    {
        // pool admin is always the adjustment recipient
        adjustmentRecipient = ISuperfluidPool(pool).admin();
        flowHash = _getPoolAdjustmentFlowHash(pool, adjustmentRecipient);
        return (adjustmentRecipient, flowHash, int256(FlowRate.unwrap(_getFlowRate(eff, flowHash))).toInt96());
    }

    function _getPoolAdjustmentFlowRate(bytes memory eff, address pool)
        internal
        view
        override
        returns (FlowRate flowRate)
    {
        (,, int96 rawFlowRate) = _getPoolAdjustmentFlowInfo(eff, pool);
        flowRate = FlowRate.wrap(int128(rawFlowRate)); // upcasting to int128 is safe
    }

    function getPoolAdjustmentFlowRate(ISuperfluidToken token, address pool) external view override returns (int96) {
        bytes memory eff = abi.encode(token);
        return int256(FlowRate.unwrap(_getPoolAdjustmentFlowRate(eff, pool))).toInt96();
    }

    function _setPoolAdjustmentFlowRate(bytes memory eff, address pool, FlowRate flowRate, Time t)
        internal
        override
        returns (bytes memory)
    {
        return _setPoolAdjustmentFlowRate(eff, pool, false, /* doShift? */ flowRate, t);
    }

    function _setPoolAdjustmentFlowRate(bytes memory eff, address pool, bool doShiftFlow, FlowRate flowRate, Time t)
        internal
        returns (bytes memory)
    {
        address adjustmentRecipient = ISuperfluidPool(pool).admin();
        bytes32 adjustmentFlowHash = _getPoolAdjustmentFlowHash(pool, adjustmentRecipient);

        if (doShiftFlow) {
            flowRate = flowRate + _getFlowRate(eff, adjustmentFlowHash);
        }
        eff = _doFlow(eff, pool, adjustmentRecipient, adjustmentFlowHash, flowRate, t);
        return eff;
    }

    /// @inheritdoc IGeneralDistributionAgreementV1
    function isPool(ISuperfluidToken token, address account) external view override returns (bool) {
        return _isPool(token, account);
    }

    function _isPool(ISuperfluidToken token, address account) internal view returns (bool exists) {
        // @note see createPool, we retrieve the isPool bit from
        // UniversalIndex for this pool to determine whether the account
        // is a pool
        bytes32[] memory slotData =
            token.getAgreementStateSlot(address(this), account, _UNIVERSAL_INDEX_STATE_SLOT_ID, 1);
        exists = ((uint256(slotData[0]) << 224) >> 224) & 1 == 1;
    }
}
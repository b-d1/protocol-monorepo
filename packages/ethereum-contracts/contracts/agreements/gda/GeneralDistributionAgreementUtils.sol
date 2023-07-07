// SPDX-License-Identifier: AGPLv3
pragma solidity 0.8.19;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "@superfluid-finance/solidity-semantic-money/src/SemanticMoney.sol";

import { ISuperfluidToken } from "../../interfaces/superfluid/ISuperfluidToken.sol";
import { ISuperfluidPool } from "../../interfaces/superfluid/ISuperfluidPool.sol";
import { UniversalIndexData, FlowDistributionData, PoolMemberData } from "./static/Structs.sol";
import { SlotsBitmapLibrary } from "../../libs/SlotsBitmapLibrary.sol";

abstract contract GeneralDistributionAgreementUtils {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SemanticMoney for BasicParticle;

    /// @dev Universal Index state slot id for storing universal index data
    uint256 internal constant _UNIVERSAL_INDEX_STATE_SLOT_ID = 0;
    /// @dev Pool member state slot id for storing subs bitmap
    uint256 internal constant _POOL_SUBS_BITMAP_STATE_SLOT_ID = 1;
    /// @dev Pool member state slot id starting point for pool connections
    uint256 internal constant _POOL_CONNECTIONS_DATA_STATE_SLOT_ID_START = 1 << 128;
    /// @dev CFAv1 PPP Config Key
    bytes32 internal constant CFAV1_PPP_CONFIG_KEY =
        keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1.PPPConfiguration");

    bytes32 internal constant SUPERTOKEN_MINIMUM_DEPOSIT_KEY =
        keccak256("org.superfluid-finance.superfluid.superTokenMinimumDeposit");

    // Hash Getters

    function _getPoolMemberHash(address poolMember, ISuperfluidPool pool) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, "poolMember", poolMember, address(pool)));
    }

    function _getFlowDistributionHash(address from, ISuperfluidPool to) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, "distributionFlow", from, to));
    }

    function _getPoolAdjustmentFlowHash(address from, address to) internal view returns (bytes32) {
        // this will never be in conflict with other flow has types
        return keccak256(abi.encode(block.chainid, "poolAdjustmentFlow", from, to));
    }

    // # Universal Index operations
    //
    // Universal Index packing:
    // store buffer (96) and one bit to specify is pool in free
    // -------- ------------------ ------------------ ------------------ ------------------
    // WORD 1: |     flowRate     |     settledAt    |    totalBuffer   |      isPool      |
    // -------- ------------------ ------------------ ------------------ ------------------
    //         |        96b       |       32b        |       96b        |        32b       |
    // -------- ------------------ ------------------ ------------------ ------------------
    // WORD 2: |                                settledValue                               |
    // -------- ------------------ ------------------ ------------------ ------------------
    //         |                                    256b                                   |
    // -------- ------------------ ------------------ ------------------ ------------------

    // TODO: Consider not using function parameter overloading but explicit function names
    function _encodeUniversalIndexData(BasicParticle memory p, uint256 buffer, bool isPool_)
        internal
        pure
        returns (bytes32[] memory data)
    {
        data = new bytes32[](2);
        // TODO: Consider simplifying/rewritting the following logic
        data[0] = bytes32(
            (uint256(int256(FlowRate.unwrap(p.flow_rate()))) << 160) | (uint256(Time.unwrap(p.settled_at())) << 128)
                | (buffer << 32) | (isPool_ ? 1 : 0)
        );
        data[1] = bytes32(uint256(Value.unwrap(p._settled_value)));
    }

    // TODO: Consider not using function parameter overloading but explicit function names
    function _encodeUniversalIndexData(UniversalIndexData memory uIndexData)
        internal
        pure
        returns (bytes32[] memory data)
    {
        data = new bytes32[](2);
        // TODO: Consider simplifying/rewritting the following logic
        data[0] = bytes32(
            (uint256(int256(uIndexData.flowRate)) << 160) | (uint256(uIndexData.settledAt) << 128)
                | (uint256(uIndexData.totalBuffer) << 32) | (uIndexData.isPool ? 1 : 0)
        );
        data[1] = bytes32(uint256(uIndexData.settledValue));
    }

    function _decodeUniversalIndexData(bytes32[] memory data)
        internal
        pure
        returns (bool exists, UniversalIndexData memory universalIndexData)
    {
        uint256 a = uint256(data[0]);
        uint256 b = uint256(data[1]);

        exists = a > 0 || b > 0;

        if (exists) {
            universalIndexData.flowRate = int96(int256(a >> 160) & int256(uint256(type(uint96).max)));
            universalIndexData.settledAt = uint32(uint256(a >> 128) & uint256(type(uint32).max));
            universalIndexData.totalBuffer = uint256(a >> 32) & uint256(type(uint96).max);
            universalIndexData.isPool = ((a << 224) >> 224) & 1 == 1;
            universalIndexData.settledValue = int256(b);
        }
    }

    function _getUIndexData(bytes memory eff, address owner)
        internal
        view
        returns (UniversalIndexData memory universalIndexData)
    {
        address token = abi.decode(eff, (address));
        bytes32[] memory data =
            ISuperfluidToken(token).getAgreementStateSlot(address(this), owner, _UNIVERSAL_INDEX_STATE_SLOT_ID, 2);
        (, universalIndexData) = _decodeUniversalIndexData(data);
    }

    function _getBasicParticleFromUIndex(UniversalIndexData memory universalIndexData)
        internal
        pure
        returns (BasicParticle memory particle)
    {
        particle._flow_rate = FlowRate.wrap(universalIndexData.flowRate);
        particle._settled_at = Time.wrap(universalIndexData.settledAt);
        particle._settled_value = Value.wrap(universalIndexData.settledValue);
    }

    // FlowDistributionData data packing:
    // -------- ---------- ------------- ---------- --------
    // WORD A: | reserved | lastUpdated | flowRate | buffer |
    // -------- ---------- ------------- ---------- --------
    //         |    32    |      32     |    96    |   96   |
    // -------- ---------- ------------- ---------- --------

    function _encodeFlowDistributionData(FlowDistributionData memory flowDistributionData)
        internal
        pure
        returns (bytes32[] memory data)
    {
        data = new bytes32[](1);
        // TODO: Consider simplifying the following math
        data[0] = bytes32(
            (uint256(uint32(flowDistributionData.lastUpdated)) << 192)
                | (uint256(uint96(flowDistributionData.flowRate)) << 96) | uint256(flowDistributionData.buffer)
        );
    }

    function _decodeFlowDistributionData(uint256 data)
        internal
        pure
        returns (bool exist, FlowDistributionData memory flowDistributionData)
    {
        exist = data > 0;
        if (exist) {
            flowDistributionData.lastUpdated = uint32((data >> 192) & uint256(type(uint32).max));
            flowDistributionData.flowRate = int96(int256(data >> 96));
            flowDistributionData.buffer = uint96(data & uint256(type(uint96).max));
        }
    }

    function _getFlowDistributionData(ISuperfluidToken token, bytes32 distributionFlowHash)
        internal
        view
        returns (bool exist, FlowDistributionData memory flowDistributionData)
    {
        bytes32[] memory data = token.getAgreementData(address(this), distributionFlowHash, 1);

        (exist, flowDistributionData) = _decodeFlowDistributionData(uint256(data[0]));
    }

    // PoolMemberData data packing:
    // -------- ---------- -------- -------------
    // WORD A: | reserved | poolID | poolAddress |
    // -------- ---------- -------- -------------
    //         |    64    |   32   |     160     |
    // -------- ---------- -------- -------------

    function _encodePoolMemberData(PoolMemberData memory poolMemberData)
        internal
        pure
        returns (bytes32[] memory data)
    {
        data = new bytes32[](1);
        data[0] = bytes32((uint256(uint32(poolMemberData.poolID)) << 160) | uint256(uint160(poolMemberData.pool)));
    }

    function _decodePoolMemberData(uint256 data)
        internal
        pure
        returns (bool exist, PoolMemberData memory poolMemberData)
    {
        exist = data > 0;
        if (exist) {
            poolMemberData.pool = address(uint160(data & uint256(type(uint160).max)));
            poolMemberData.poolID = uint32(data >> 160);
        }
    }

    function _getPoolMemberData(ISuperfluidToken token, address poolMember, ISuperfluidPool pool)
        internal
        view
        returns (bool exist, PoolMemberData memory poolMemberData)
    {
        bytes32[] memory data = token.getAgreementData(address(this), _getPoolMemberHash(poolMember, pool), 1);

        (exist, poolMemberData) = _decodePoolMemberData(uint256(data[0]));
    }

    // SlotsBitmap Pool Data:
    function _findAndFillPoolConnectionsBitmap(ISuperfluidToken token, address poolMember, bytes32 poolID)
        internal
        returns (uint32 slotId)
    {
        return SlotsBitmapLibrary.findEmptySlotAndFill(
            token, poolMember, _POOL_SUBS_BITMAP_STATE_SLOT_ID, _POOL_CONNECTIONS_DATA_STATE_SLOT_ID_START, poolID
        );
    }

    function _clearPoolConnectionsBitmap(ISuperfluidToken token, address poolMember, uint32 slotId) internal {
        SlotsBitmapLibrary.clearSlot(token, poolMember, _POOL_SUBS_BITMAP_STATE_SLOT_ID, slotId);
    }

    function _listPoolConnectionIds(ISuperfluidToken token, address subscriber)
        internal
        view
        returns (uint32[] memory slotIds, bytes32[] memory pidList)
    {
        (slotIds, pidList) = SlotsBitmapLibrary.listData(
            token, subscriber, _POOL_SUBS_BITMAP_STATE_SLOT_ID, _POOL_CONNECTIONS_DATA_STATE_SLOT_ID_START
        );
    }
}
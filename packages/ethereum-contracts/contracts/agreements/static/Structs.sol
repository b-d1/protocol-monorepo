// SPDX-License-Identifier: AGPLv3
pragma solidity 0.8.19;

import { ISuperfluidToken } from "../../interfaces/superfluid/ISuperfluidToken.sol";

struct UniversalIndexData {
    int96 flowRate;
    uint32 settledAt;
    uint256 totalBuffer;
    bool isPool;
    int256 settledValue;
}

struct FlowDistributionData {
    uint32 lastUpdated;
    int96 flowRate;
    uint256 buffer; // stored as uint96
}

struct PoolMemberData {
    address pool;
    uint32 poolID; // the slot id in the pool's subs bitmap
}

struct _StackVars_Liquidation {
    ISuperfluidToken token;
    int256 availableBalance;
    address sender;
    bytes32 distributionFlowHash;
    int256 signedTotalGDADeposit;
    address liquidator;
}

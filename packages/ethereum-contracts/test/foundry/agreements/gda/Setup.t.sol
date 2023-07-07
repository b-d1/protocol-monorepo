// SPDX-License-Identifier: AGPLv3
pragma solidity 0.8.19;

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IBeacon } from "@openzeppelin/contracts/proxy/beacon/IBeacon.sol";
import "@superfluid-finance/solidity-semantic-money/src/SemanticMoney.sol";
import "../../FoundrySuperfluidTester.sol";
import { console } from "forge-std/console.sol";
import {
    GeneralDistributionAgreementV1,
    IGeneralDistributionAgreementV1
} from "../../../../contracts/agreements/gda/GeneralDistributionAgreementV1.sol";
import {
    UniversalIndexData, FlowDistributionData, PoolMemberData
} from "../../../../contracts/agreements/gda/static/Structs.sol";
import { SuperTokenV1Library } from "../../../../contracts/apps/SuperTokenV1Library.sol";
import { ISuperToken } from "../../../../contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluidToken } from "../../../../contracts/interfaces/superfluid/ISuperfluidToken.sol";
import { ISuperfluidPool, SuperfluidPool } from "../../../../contracts/superfluid/SuperfluidPool.sol";
import { SuperfluidPoolStorageLayoutMock } from "../../../../contracts/mocks/SuperfluidPoolUpgradabilityMock.sol";

/// @title GeneralDistributionAgreementV1 Integration Tests
/// @author Superfluid
/// @notice This is a contract that runs integrations tests for the GDAv1
/// It tests interactions between contracts and more complicated interactions
/// with a range of values when applicable and it aims to ensure that the
/// these interactions work as expected.
contract GeneralDistributionAgreementV1TestSetup is FoundrySuperfluidTester {
    using SuperTokenV1Library for ISuperToken;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct UpdateMemberData {
        address member;
        uint64 newUnits;
    }

    struct ExpectedSuperfluidPoolData {
        int128 totalUnits;
        int128 connectedUnits;
        int128 disconnectedUnits;
        int96 connectedFlowRate;
        int96 disconnectedFlowRate;
        int256 disconnectedBalance;
    }

    struct ExpectedPoolMemberData {
        bool isConnected;
        uint128 ownedUnits;
        int96 flowRate;
        int96 netFlowRate;
    }

      struct PoolUpdateStep {
        uint8 u; // which user
        uint8 a; // action types: 0 update units, 1 distribute flow, 2 pool connection, 3 pool claim for, 4 distribute
        uint32 v; // action param
        uint16 dt; // time delta
    }


    SuperfluidPool public pool;
    uint256 public liquidationPeriod;
    mapping(address pool => ExpectedSuperfluidPoolData expectedData) internal _expectedPoolData;
    mapping(address pool => EnumerableSet.AddressSet members) internal _poolMembers;
    mapping(address pool => mapping(address member => ExpectedPoolMemberData expectedData)) internal
        _poolToExpectedMemberData;

    constructor() FoundrySuperfluidTester(6) { }

    function setUp() public override {
        super.setUp();
        vm.startPrank(alice);
        pool = SuperfluidPool(address(superToken.createPool(alice)));
        vm.stopPrank();
        (liquidationPeriod,) = sf.governance.getPPPConfig(sf.host, superToken);
    }
    /*//////////////////////////////////////////////////////////////////////////
                                    Helper Functions
    //////////////////////////////////////////////////////////////////////////*/

    function _helperGetValidDrainFlowRate(int256 balance) internal pure returns (int96) {
        return (balance / type(int32).max).toInt96();
    }

    function _helperWarpToCritical(address account_, int96 netFlowRate_, uint256 secondsCritical_) internal {
        assertTrue(secondsCritical_ > 0, "_helperWarpToCritical: secondsCritical_ must be > 0 to reach critical");
        (int256 ab,,) = superToken.realtimeBalanceOf(account_, block.timestamp);
        int256 timeToZero = ab / netFlowRate_;
        uint256 amountToWarp = timeToZero.toUint256() + secondsCritical_;
        vm.warp(block.timestamp + amountToWarp);
        assertTrue(superToken.isAccountCriticalNow(account_), "_helperWarpToCritical: account is not critical");
    }

    function _helperWarpToInsolvency(
        address account_,
        int96 netFlowRate_,
        uint256 liquidationPeriod_,
        uint256 secondsInsolvent_
    ) internal {
        assertTrue(secondsInsolvent_ > 0, "_helperWarpToInsolvency: secondsInsolvent_ must be > 0 to reach insolvency");
        (int256 ab,,) = superToken.realtimeBalanceOf(account_, block.timestamp);
        int256 timeToZero = ab / netFlowRate_;
        uint256 amountToWarp = timeToZero.toUint256() + liquidationPeriod_ + secondsInsolvent_;
        vm.warp(block.timestamp + amountToWarp);
        assertFalse(superToken.isAccountSolventNow(account_), "_helperWarpToInsolvency: account is still solvent");
    }

    function _helperGetMemberInitialState(ISuperfluidPool pool_, address member_)
        internal
        returns (bool isConnected, int256 oldUnits, int96 oldFlowRate)
    {
        oldUnits = uint256(pool_.getUnits(member_)).toInt256();
        assertEq(
            oldUnits,
            pool_.balanceOf(member_).toInt256(),
            "_helperGetMemberInitialState: member units != member balanceOf"
        );
        isConnected = sf.gda.isMemberConnected(pool_, member_);
        oldFlowRate = pool_.getMemberFlowRate(member_);
    }

    function _helperUpdateMemberUnits(ISuperfluidPool pool_, address caller_, address member_, uint128 newUnits_)
        internal
    {
        if (caller_ == address(0) || member_ == address(0) || sf.gda.isPool(superToken, member_)) return;

        (bool isConnected, int256 oldUnits, int96 oldFlowRate) = _helperGetMemberInitialState(pool_, member_);

        vm.startPrank(caller_);
        pool_.updateMember(member_, newUnits_);
        vm.stopPrank();
        assertEq(pool_.getUnits(member_), newUnits_, "GDAv1.t: Units incorrectly set");

        int256 unitsDelta = uint256(newUnits_).toInt256() - oldUnits;

        // Update Expected Pool Data
        _expectedPoolData[address(pool_)].totalUnits += unitsDelta.toInt128();
        _expectedPoolData[address(pool_)].connectedUnits += isConnected ? unitsDelta.toInt128() : int128(0);
        _expectedPoolData[address(pool_)].disconnectedUnits += isConnected ? int128(0) : unitsDelta.toInt128();
        // TODO: how do we get the connected/disconnected/adjustment flow rates and connected balance?
        // NOTE: actualFlowRate of all distributors should be totalDistributionFlowRate + adjustmentFlowRate
        // we should not recalculate the adjustment flow rate and other flow rates, but we should keep track
        // of the changes in flow rates and ensure that the global invariants hold for those instead of
        // duplicating the logic here and asserting that the state changes occuring in the code is the same
        // as the state changes replicated in here

        // Update Expected Member Data
        if (newUnits_ > 0) {
            // @note You are only considered a member if you are given units
            _poolMembers[address(pool_)].add(member_);
        }
        // TODO: how does flowRate/netFlowRate for a member get impacted by this?

        // Assert Pool Units are set
        _assertPoolUnits(pool_);
    }

    function _helperConnectPool(address caller_, ISuperfluidToken superToken_, ISuperfluidPool pool_) internal {
        (bool isConnected, int256 oldUnits, int96 oldFlowRate) = _helperGetMemberInitialState(pool_, caller_);

        vm.startPrank(caller_);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeWithSelector(IGeneralDistributionAgreementV1.connectPool.selector, pool_, ""),
            new bytes(0)
        );
        vm.stopPrank();

        assertEq(sf.gda.isMemberConnected(superToken_, address(pool_), caller_), true, "GDAv1.t: Member not connected");

        // Update Expected Pool Data
        _expectedPoolData[address(pool_)].connectedUnits += isConnected ? int128(0) : oldUnits.toInt128();
        _expectedPoolData[address(pool_)].disconnectedUnits -= isConnected ? int128(0) : oldUnits.toInt128();
        _expectedPoolData[address(pool_)].connectedFlowRate += isConnected ? int96(0) : oldFlowRate;
        _expectedPoolData[address(pool_)].disconnectedFlowRate -= isConnected ? int96(0) : oldFlowRate;

        // Update Expected Member Data
        // TODO how does the flow rate change here
    }

    function _helperDisconnectPool(address caller_, ISuperfluidToken superToken_, ISuperfluidPool pool_) internal {
        (bool isConnected, int256 oldUnits, int96 oldFlowRate) = _helperGetMemberInitialState(pool_, caller_);

        vm.startPrank(caller_);
        sf.host.callAgreement(sf.gda, abi.encodeCall(sf.gda.disconnectPool, (pool_, new bytes(0))), new bytes(0));
        vm.stopPrank();

        assertEq(
            sf.gda.isMemberConnected(superToken_, address(pool_), caller_),
            false,
            "GDAv1.t D/C: Member not disconnected"
        );

        // Update Expected Pool Data
        _expectedPoolData[address(pool_)].connectedUnits -= isConnected ? oldUnits.toInt128() : int128(0);
        _expectedPoolData[address(pool_)].disconnectedUnits += isConnected ? oldUnits.toInt128() : int128(0);
        _expectedPoolData[address(pool_)].connectedFlowRate -= isConnected ? oldFlowRate : int96(0);
        _expectedPoolData[address(pool_)].disconnectedFlowRate += isConnected ? oldFlowRate : int96(0);

        // Update Expected Member Data
        // TODO how does the flow rate change here
    }

    function _helperDistribute(
        ISuperfluidToken _superToken,
        address caller,
        address from,
        ISuperfluidPool _pool,
        uint256 requestedAmount
    ) internal {
        (int256 fromRTBBefore,,,) = superToken.realtimeBalanceOfNow(from);

        uint256 actualAmount = sf.gda.estimateDistributionActualAmount(superToken, alice, pool, requestedAmount);

        address[] memory members = _poolMembers[address(_pool)].values();
        uint256[] memory memberBalancesBefore = new uint256[](members.length);

        for (uint256 i = 0; i < members.length; ++i) {
            (int256 memberRTB,,,) = superToken.realtimeBalanceOfNow(members[i]);
            memberBalancesBefore[i] = uint256(memberRTB);
        }

        vm.startPrank(caller);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distribute, (_superToken, from, _pool, requestedAmount, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();

        // Assert Distributor RTB
        (int256 fromRTBAfter,,,) = superToken.realtimeBalanceOfNow(from);
        assertEq(fromRTBAfter, fromRTBBefore - int256(actualAmount), "GDAv1.t D: Distributor RTB incorrect");

        if (members.length == 0) return;

        // Assert Members RTB
        uint256 amountPerUnit = actualAmount / _pool.getTotalUnits();
        for (uint256 i = 0; i < members.length; ++i) {
            (int256 memberRTB,,,) = superToken.realtimeBalanceOfNow(members[i]);
            uint256 amountReceived = sf.gda.isMemberConnected(superToken, address(pool), members[i])
                ? uint256(_pool.getUnits(members[i])) * amountPerUnit
                : 0;
            assertEq(uint256(memberRTB), memberBalancesBefore[i] + amountReceived, "GDAv1.t D: Member RTB incorrect");
        }
    }

    function _helperDistributeFlow(
        ISuperfluidToken _superToken,
        address caller,
        address from,
        ISuperfluidPool _pool,
        int96 requestedFlowRate
    ) internal {
        vm.startPrank(caller);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distributeFlow, (_superToken, from, _pool, requestedFlowRate, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function _helperApprove(ISuperfluidPool _pool, address owner, address spender, uint256 amount) internal {
        vm.startPrank(owner);
        _pool.approve(spender, amount);
        vm.stopPrank();

        _assertPoolAllowance(_pool, owner, spender, amount);
    }

    function _helperIncreaseAllowance(ISuperfluidPool _pool, address owner, address spender, uint256 addedValue)
        internal
    {
        uint256 allowanceBefore = _pool.allowance(owner, spender);

        vm.startPrank(owner);
        _pool.increaseAllowance(spender, addedValue);
        vm.stopPrank();

        _assertPoolAllowance(_pool, owner, spender, allowanceBefore + addedValue);
    }

    function _helperDecreaseAllowance(ISuperfluidPool _pool, address owner, address spender, uint256 subtractedValue)
        internal
    {
        uint256 allowanceBefore = _pool.allowance(owner, spender);

        vm.startPrank(owner);
        _pool.decreaseAllowance(spender, subtractedValue);
        vm.stopPrank();

        _assertPoolAllowance(_pool, owner, spender, allowanceBefore - subtractedValue);
    }

    function _helperPoolUnitsTransfer(ISuperfluidPool _pool, address from, address to, uint256 amount) internal {
        uint256 fromBalanceOfBefore = _pool.balanceOf(from);
        uint256 toBalanceOfBefore = _pool.balanceOf(to);

        vm.startPrank(from);
        _pool.transfer(to, amount);
        vm.stopPrank();

        uint256 fromBalanceOfAfter = _pool.balanceOf(from);
        uint256 toBalanceOfAfter = _pool.balanceOf(to);
        assertEq(fromBalanceOfBefore - amount, fromBalanceOfAfter, "_helperPoolUnitsTransfer: from balance mismatch");
        assertEq(toBalanceOfBefore + amount, toBalanceOfAfter, "_helperPoolUnitsTransfer: to balance mismatch");
    }

    function _helperPoolUnitsTransferFrom(
        ISuperfluidPool _pool,
        address caller,
        address from,
        address to,
        uint256 amount
    ) internal {
        uint256 fromBalanceOfBefore = _pool.balanceOf(from);
        uint256 toBalanceOfBefore = _pool.balanceOf(to);
        uint256 allowanceBefore = _pool.allowance(from, caller);

        vm.startPrank(caller);
        _pool.transferFrom(from, to, amount);
        vm.stopPrank();

        uint256 fromBalanceOfAfter = _pool.balanceOf(from);
        uint256 toBalanceOfAfter = _pool.balanceOf(to);
        uint256 allowanceAfter = _pool.allowance(from, caller);
        assertEq(
            fromBalanceOfBefore - amount, fromBalanceOfAfter, "_helperPoolUnitsTransferFrom: from balance mismatch"
        );
        assertEq(toBalanceOfBefore + amount, toBalanceOfAfter, "_helperPoolUnitsTransferFrom: to balance mismatch");
        assertEq(allowanceBefore - amount, allowanceAfter, "_helperPoolUnitsTransferFrom: allowance mismatch");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Assertion Functions
    //////////////////////////////////////////////////////////////////////////*/

    function _assertGlobalInvariants() internal override {
        super._assertGlobalInvariants();
        // @note we can rename this pool variable to currentPool
        _assertPoolUnits(pool);
    }

    function _assertPoolUnits(ISuperfluidPool _pool) internal {
        _assertPoolTotalUnits(_pool);
        _assertPoolConnectedUnits(_pool);
        _assertPoolDisconnectedUnits(_pool);
    }

    function _assertPoolDisconnectedUnits(ISuperfluidPool _pool) internal {
        int128 disconnectedUnits = uint256(_pool.getTotalDisconnectedUnits()).toInt256().toInt128();
        assertEq(
            _expectedPoolData[address(_pool)].disconnectedUnits,
            disconnectedUnits,
            "_assertPoolDisconnectedUnits: Pool disconnected units incorrect"
        );
    }

    function _assertPoolConnectedUnits(ISuperfluidPool _pool) internal {
        int128 connectedUnits = uint256(_pool.getTotalConnectedUnits()).toInt256().toInt128();

        assertEq(
            _expectedPoolData[address(_pool)].totalUnits - _expectedPoolData[address(_pool)].disconnectedUnits,
            connectedUnits,
            "_assertPoolConnectedUnits: Pool disconnected units incorrect"
        );
    }

    function _assertPoolTotalUnits(ISuperfluidPool _pool) internal {
        int128 totalUnits = uint256(_pool.getTotalUnits()).toInt256().toInt128();
        int128 totalSupply = _pool.totalSupply().toInt256().toInt128();

        assertEq(
            _expectedPoolData[address(_pool)].totalUnits,
            totalUnits,
            "_assertPoolTotalUnits: Pool total units incorrect"
        );
        assertEq(totalUnits, totalSupply, "_assertPoolTotalUnits: Pool total units != total supply");
    }

    function _assertPoolAllowance(ISuperfluidPool _pool, address owner, address spender, uint256 expectedAllowance)
        internal
    {
        assertEq(_pool.allowance(owner, spender), expectedAllowance, "_assertPoolAllowance: allowance mismatch");
    }

}

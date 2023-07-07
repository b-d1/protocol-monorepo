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
import { GeneralDistributionAgreementV1TestSetup } from "./Setup.t.sol";

/// @title GeneralDistributionAgreementV1 Integration Tests
/// @author Superfluid
/// @notice This is a contract that runs integrations tests for the GDAv1
/// It tests interactions between contracts and more complicated interactions
/// with a range of values when applicable and it aims to ensure that the
/// these interactions work as expected.
contract GeneralDistributionAgreementV1IntegrationTest is GeneralDistributionAgreementV1TestSetup {
    using SuperTokenV1Library for ISuperToken;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;
    using SafeCast for int256;

    constructor() GeneralDistributionAgreementV1TestSetup() { }

    /*//////////////////////////////////////////////////////////////////////////
                                GDA Integration Tests
    //////////////////////////////////////////////////////////////////////////*/

    function testInitializeGDA(IBeacon beacon) public {
        GeneralDistributionAgreementV1 gdaV1 = new GeneralDistributionAgreementV1(sf.host);
        assertEq(address(gdaV1.superfluidPoolBeacon()), address(0), "GDAv1.t: Beacon address not address(0)");
        gdaV1.initialize(beacon);

        assertEq(address(gdaV1.superfluidPoolBeacon()), address(beacon), "GDAv1.t: Beacon address not equal");
    }

    function testRevertReinitializeGDA(IBeacon beacon) public {
        vm.expectRevert("Initializable: contract is already initialized");
        sf.gda.initialize(beacon);
    }

    function testRevertAppendIndexUpdateByPoolByNonPool(BasicParticle memory p, Time t) public {
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_ONLY_SUPER_TOKEN_POOL.selector);
        sf.gda.appendIndexUpdateByPool(superToken, p, t);
    }

    function testRevertPoolSettleClaimByNonPool(address claimRecipient, int256 amount) public {
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_ONLY_SUPER_TOKEN_POOL.selector);
        sf.gda.poolSettleClaim(superToken, claimRecipient, amount);
    }

    function testProxiableUUIDIsExpectedValue() public {
        assertEq(pool.proxiableUUID(), keccak256("org.superfluid-finance.contracts.SuperfluidPool.implementation"));
    }

    function testPositiveBalanceIsPatricianPeriodNow(address account) public {
        (bool isPatricianPeriod,) = sf.gda.isPatricianPeriodNow(superToken, account);
        assertEq(isPatricianPeriod, true);
    }

    function testNegativeBalanceIsPatricianPeriodNowIsTrue() public {
        uint256 balance = superToken.balanceOf(alice);
        int96 flowRate = balance.toInt256().toInt96() / type(int32).max;
        int96 requestedDistributionFlowRate = int96(flowRate);

        _helperConnectPool(bob, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, bob, 1);

        (int96 actualDistributionFlowRate,) =
            sf.gda.estimateFlowDistributionActualFlowRate(superToken, alice, pool, requestedDistributionFlowRate);

        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);
        int96 fr = sf.gda.getFlowRate(superToken, alice, pool);

        uint256 aliceBalance = superToken.balanceOf(alice);

        _helperWarpToCritical(alice, actualDistributionFlowRate, 1);

        (bool isPatricianPeriod,) = sf.gda.isPatricianPeriodNow(superToken, alice);
        assertEq(isPatricianPeriod, true);
    }

    function testNegativeBalanceIsPatricianPeriodNowIsFalse() public {
        uint256 balance = superToken.balanceOf(alice);
        int96 flowRate = balance.toInt256().toInt96() / type(int32).max;
        int96 requestedDistributionFlowRate = int96(flowRate);

        _helperConnectPool(bob, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, bob, 1);

        (int96 actualDistributionFlowRate,) =
            sf.gda.estimateFlowDistributionActualFlowRate(superToken, alice, pool, requestedDistributionFlowRate);

        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);

        if (actualDistributionFlowRate > 0) {
            _helperWarpToInsolvency(alice, actualDistributionFlowRate, liquidationPeriod, 1);
        }

        (bool isPatricianPeriod,) = sf.gda.isPatricianPeriodNow(superToken, alice);
        assertEq(isPatricianPeriod, false);
    }

    function testNegativeBalanceIsPatricianPeriodNowIsFalseWithZeroDeposit() public {
        uint256 aliceBalance = superToken.balanceOf(alice);
        uint256 bobBalance = superToken.balanceOf(bob);
        int96 flowRate = aliceBalance.toInt256().toInt96() / type(int32).max;
        int96 requestedDistributionFlowRate = int96(flowRate);

        vm.startPrank(sf.governance.owner());
        sf.governance.setRewardAddress(sf.host, ISuperfluidToken(address(0)), alice);
        vm.stopPrank();

        _helperConnectPool(bob, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, bob, 1);

        (int256 aliceRTB, uint256 deposit,,) = superToken.realtimeBalanceOfNow(alice);

        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);
        int96 fr = sf.gda.getFlowRate(superToken, alice, pool);

        vm.warp(block.timestamp + (INIT_SUPER_TOKEN_BALANCE / uint256(uint96(fr))));

        (aliceRTB, deposit,,) = superToken.realtimeBalanceOfNow(alice);

        _helperDistributeFlow(superToken, bob, alice, pool, 0);

        (bool isPatricianPeriod,) = sf.gda.isPatricianPeriodNow(superToken, alice);
        // TODO
        assertEq(isPatricianPeriod, false, "false patrician period");
    }

    function testCreatePool() public {
        vm.prank(alice);
        SuperfluidPool localPool = SuperfluidPool(address(sf.gda.createPool(superToken, alice)));
        assertTrue(sf.gda.isPool(superToken, address(localPool)), "GDAv1.t: Created pool is not pool");
    }

    function testRevertConnectPoolByNonHost(address notHost) public {
        vm.assume(notHost != address(sf.host));
        vm.startPrank(notHost);
        vm.expectRevert("unauthorized host");
        sf.gda.connectPool(pool, "0x");
        vm.stopPrank();
    }

    function testRevertNonHostDisconnectPool(address notHost) public {
        vm.assume(notHost != address(sf.host));
        vm.startPrank(notHost);
        vm.expectRevert("unauthorized host");
        sf.gda.disconnectPool(pool, "0x");
        vm.stopPrank();
    }

    function testConnectPool(address caller) public {
        _helperConnectPool(caller, superToken, pool);
    }

    function testDisconnectPool(address caller) public {
        _helperConnectPool(caller, superToken, pool);
        _helperDisconnectPool(caller, superToken, pool);
    }

    function testRevertDistributeFlowToNonPool(int96 requestedFlowRate) public {
        vm.assume(requestedFlowRate >= 0);
        vm.assume(requestedFlowRate < int96(type(int64).max));
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_ONLY_SUPER_TOKEN_POOL.selector);
        _helperDistributeFlow(superToken, alice, alice, ISuperfluidPool(bob), requestedFlowRate);
    }

    function testRevertDistributeFlowWithNegativeFlowRate(int96 requestedFlowRate) public {
        vm.assume(requestedFlowRate < 0);

        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_NO_NEGATIVE_FLOW_RATE.selector);
        _helperDistributeFlow(superToken, alice, alice, pool, requestedFlowRate);
    }

    function testRevertDistributeToNonPool(uint256 requestedAmount) public {
        vm.assume(requestedAmount < uint256(type(uint128).max));

        vm.startPrank(alice);
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_ONLY_SUPER_TOKEN_POOL.selector);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distribute, (superToken, alice, ISuperfluidPool(bob), requestedAmount, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testRevertDistributeForOthers(address signer, uint256 requestedAmount) public {
        vm.assume(requestedAmount < uint256(type(uint128).max));
        vm.assume(signer != alice);

        vm.startPrank(signer);
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_DISTRIBUTE_FOR_OTHERS_NOT_ALLOWED.selector);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distribute, (superToken, alice, pool, requestedAmount, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testRevertDistributeFlowForOthers(address signer, int32 requestedFlowRate) public {
        vm.assume(requestedFlowRate > 0);
        vm.assume(signer != alice);

        vm.startPrank(signer);
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_DISTRIBUTE_FOR_OTHERS_NOT_ALLOWED.selector);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distributeFlow, (superToken, alice, pool, requestedFlowRate, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testRevertDistributeFlowInsufficientBalance() public {
        uint256 balance = superToken.balanceOf(alice);
        balance /= 4 hours;
        int96 tooBigFlowRate = int96(int256(balance)) + 1;

        _helperConnectPool(bob, superToken, pool);

        _helperUpdateMemberUnits(pool, alice, bob, 1);
        vm.startPrank(alice);
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_INSUFFICIENT_BALANCE.selector);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distributeFlow, (superToken, alice, pool, tooBigFlowRate, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testRevertLiquidateNonCriticalDistributor(int32 flowRate, int96 units) public {
        vm.assume(flowRate > 0);
        _helperConnectPool(bob, superToken, pool);

        _helperUpdateMemberUnits(pool, alice, bob, uint96(units));

        _helperDistributeFlow(superToken, alice, alice, pool, flowRate);

        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_NON_CRITICAL_SENDER.selector);
        _helperDistributeFlow(superToken, bob, alice, pool, 0);
    }

    function testRevertDistributeInsufficientBalance() public {
        uint256 balance = superToken.balanceOf(alice);

        _helperConnectPool(bob, superToken, pool);

        _helperUpdateMemberUnits(pool, alice, bob, 1);

        vm.startPrank(alice);
        vm.expectRevert(IGeneralDistributionAgreementV1.GDA_INSUFFICIENT_BALANCE.selector);
        sf.host.callAgreement(
            sf.gda,
            abi.encodeCall(sf.gda.distribute, (superToken, alice, pool, balance + 1, new bytes(0))),
            new bytes(0)
        );
        vm.stopPrank();
    }

    function testRevertPoolOperatorConnectMember(address notOperator, address member, bool doConnect, uint32 time)
        public
    {
        vm.assume(notOperator != address(sf.gda));
        vm.startPrank(notOperator);
        vm.expectRevert(ISuperfluidPool.SUPERFLUID_POOL_NOT_GDA.selector);
        pool.operatorConnectMember(member, doConnect, time);
        vm.stopPrank();
    }

    function testRevertPoolUpdateMemberThatIsPool(uint128 units) public {
        vm.assume(units < uint128(type(int128).max));

        vm.expectRevert(ISuperfluidPool.SUPERFLUID_POOL_NO_POOL_MEMBERS.selector);
        vm.startPrank(alice);
        pool.updateMember(address(pool), units);
        vm.stopPrank();
    }

    function testSuperfluidPoolStorageLayout() public {
        SuperfluidPoolStorageLayoutMock mock = new SuperfluidPoolStorageLayoutMock(sf.gda);
        mock.validateStorageLayout();
    }

    function testDistributeFlowUsesMinDeposit(uint64 distributionFlowRate, uint32 minDepositMultiplier, address member)
        public
    {
        vm.assume(distributionFlowRate < minDepositMultiplier);
        vm.assume(distributionFlowRate > 0);
        vm.assume(member != address(pool));
        vm.assume(member != address(0));

        vm.startPrank(address(sf.governance.owner()));
        uint256 minimumDeposit = 4 hours * uint256(minDepositMultiplier);
        sf.governance.setSuperTokenMinimumDeposit(sf.host, superToken, minimumDeposit);
        vm.stopPrank();

        _helperConnectPool(member, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, member, 1);
        _helperDistributeFlow(superToken, alice, alice, pool, int96(int64(distributionFlowRate)));
        (, uint256 buffer,,) = superToken.realtimeBalanceOfNow(alice);
        assertEq(buffer, minimumDeposit, "GDAv1.t: Min buffer should be used");
    }

    function testDistributeFlowIgnoresMinDeposit(
        int32 distributionFlowRate,
        uint32 minDepositMultiplier,
        address member
    ) public {
        vm.assume(uint32(distributionFlowRate) >= minDepositMultiplier);
        vm.assume(distributionFlowRate > 0);
        vm.assume(member != address(0));
        vm.assume(member != address(pool));
        vm.startPrank(address(sf.governance.owner()));

        uint256 minimumDeposit = 4 hours * uint256(minDepositMultiplier);
        sf.governance.setSuperTokenMinimumDeposit(sf.host, superToken, minimumDeposit);
        vm.stopPrank();

        _helperConnectPool(member, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, member, 1);
        _helperDistributeFlow(superToken, alice, alice, pool, int96(distributionFlowRate));
        (, uint256 buffer,,) = superToken.realtimeBalanceOfNow(alice);
        assertTrue(buffer >= minimumDeposit, "GDAv1.t: Buffer should be >= minDeposit");
    }

    function testDistributeFlowToConnectedMemberSendingToCFA(int32 flowRate, uint64 units) public {
        vm.assume(flowRate > 0);
        // alice creates pool in setUp()
        int96 requestedDistributionFlowRate = int96(flowRate);

        uint128 memberUnits = uint128(units);

        _helperUpdateMemberUnits(pool, alice, bob, memberUnits);

        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);

        // bob sends a flow of 1 to carol
        _helperConnectPool(bob, superToken, pool);
        vm.startPrank(bob);
        superToken.createFlow(alice, requestedDistributionFlowRate * 10);
        vm.stopPrank();

        int96 aliceGDANetFlowRate = sf.gda.getNetFlow(superToken, alice);
        int96 bobGDANetFlowRate = sf.gda.getNetFlow(superToken, bob);
        int96 aliceCFANetFlowRate = sf.cfa.getNetFlow(superToken, alice);
        int96 bobCFANetFlowRate = sf.cfa.getNetFlow(superToken, bob);
        assertEq(
            aliceGDANetFlowRate + bobGDANetFlowRate + aliceCFANetFlowRate + bobCFANetFlowRate,
            0,
            "alice and bob GDA net flow rates !="
        );
    }

    function testDistributeToEmptyPool(uint64 distributionAmount) public {
        _helperDistribute(superToken, alice, alice, pool, distributionAmount);
    }

    function testDistributeFlowToEmptyPool(int32 flowRate) public {
        vm.assume(flowRate >= 0);
        _helperDistributeFlow(superToken, alice, alice, pool, flowRate);
        int96 distributionFlowRate = sf.gda.getFlowRate(superToken, alice, pool);
        assertEq(distributionFlowRate, 0, "GDAv1.t: distributionFlowRate should be 0");
    }

    function testDistributeFlowCriticalLiquidation(uint64 units) public {
        uint256 balance = superToken.balanceOf(alice);
        int96 flowRate = balance.toInt256().toInt96() / type(int32).max;
        int96 requestedDistributionFlowRate = int96(flowRate);

        uint128 memberUnits = uint128(units);

        _helperConnectPool(bob, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, bob, memberUnits);

        (int96 actualDistributionFlowRate,) =
            sf.gda.estimateFlowDistributionActualFlowRate(superToken, alice, pool, requestedDistributionFlowRate);

        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);
        int96 fr = sf.gda.getFlowRate(superToken, alice, pool);

        uint256 aliceBalance = superToken.balanceOf(alice);

        if (actualDistributionFlowRate > 0) {
            _helperWarpToCritical(alice, actualDistributionFlowRate, 1);
            uint256 timeToCritical = aliceBalance / int256(actualDistributionFlowRate).toUint256();
            _helperDistributeFlow(superToken, bob, alice, pool, 0);
        }
    }

    function testDistributeFlowInsolventLiquidation(uint64 units) public {
        uint256 balance = superToken.balanceOf(alice);
        int96 flowRate = balance.toInt256().toInt96() / type(int32).max;
        int96 requestedDistributionFlowRate = int96(flowRate);

        uint128 memberUnits = uint128(units);

        _helperConnectPool(bob, superToken, pool);
        _helperUpdateMemberUnits(pool, alice, bob, memberUnits);
        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);

        (int96 actualDistributionFlowRate,) =
            sf.gda.estimateFlowDistributionActualFlowRate(superToken, alice, pool, requestedDistributionFlowRate);

        _helperDistributeFlow(superToken, alice, alice, pool, requestedDistributionFlowRate);
        int96 fr = sf.gda.getFlowRate(superToken, alice, pool);

        uint256 aliceBalance = superToken.balanceOf(alice);

        if (actualDistributionFlowRate > 0) {
            _helperWarpToInsolvency(alice, actualDistributionFlowRate, liquidationPeriod, 1);
            uint256 timeToCritical = aliceBalance / int256(actualDistributionFlowRate).toUint256();
            _helperDistributeFlow(superToken, bob, alice, pool, 0);
        }
    }

    function testDistributeToDisconnectedMembers(
        UpdateMemberData[5] memory members,
        uint256 distributionAmount,
        uint16 warpTime
    ) public {
        address distributor = alice;
        uint256 distributorBalance = superToken.balanceOf(distributor);

        vm.assume(members.length > 0);
        vm.assume(distributionAmount < distributorBalance);

        for (uint256 i = 0; i < members.length; ++i) {
            _helperUpdateMemberUnits(pool, alice, members[i].member, members[i].newUnits);
        }
        _helperDistribute(superToken, alice, alice, pool, distributionAmount);
    }

    function testDistributeToConnectedMembers(
        UpdateMemberData[5] memory members,
        uint256 distributionAmount,
        uint16 warpTime
    ) public {
        address distributor = alice;
        uint256 distributorBalance = superToken.balanceOf(distributor);

        vm.assume(members.length > 0);
        vm.assume(distributionAmount < distributorBalance);

        for (uint256 i = 0; i < members.length; ++i) {
            _helperConnectPool(members[i].member, superToken, pool);
            _helperUpdateMemberUnits(pool, alice, members[i].member, members[i].newUnits);
        }
        _helperDistribute(superToken, alice, alice, pool, distributionAmount);
    }

    function testDistributeFlowToConnectedMembers(UpdateMemberData[5] memory members, int32 flowRate, uint16 warpTime)
        public
    {
        vm.assume(members.length > 0);
        vm.assume(flowRate > 0);

        for (uint256 i = 0; i < members.length; ++i) {
            _helperConnectPool(members[i].member, superToken, pool);
            _helperUpdateMemberUnits(pool, alice, members[i].member, members[i].newUnits);
        }

        _helperDistributeFlow(superToken, alice, alice, pool, 100);
        assertEq(
            sf.gda.getPoolAdjustmentFlowRate(superToken, address(pool)), 0, "GDAv1.t: Pool adjustment rate is non-zero"
        );
    }

    function testDistributeFlowToUnconnectedMembers(UpdateMemberData[5] memory members, int32 flowRate, uint16 warpTime)
        public
    {
        vm.assume(flowRate > 0);
        vm.assume(members.length > 0);

        for (uint256 i = 0; i < members.length; ++i) {
            _helperUpdateMemberUnits(pool, alice, members[i].member, members[i].newUnits);
        }

        int96 requestedFlowRate = flowRate;
        _helperDistributeFlow(superToken, alice, alice, pool, requestedFlowRate);
        (int96 actualDistributionFlowRate,) =
            sf.gda.estimateFlowDistributionActualFlowRate(superToken, alice, pool, requestedFlowRate);

        vm.warp(block.timestamp + warpTime);

        uint128 totalUnits = pool.getTotalUnits();

        for (uint256 i; i < members.length; ++i) {
            address member = members[i].member;
            // @note we test realtimeBalanceOfNow here as well
            (int256 memberRTB,,) = sf.gda.realtimeBalanceOf(superToken, member, block.timestamp);
            (int256 rtbNow,,,) = sf.gda.realtimeBalanceOfNow(superToken, member);
            assertEq(memberRTB, rtbNow, "testDistributeFlowToUnconnectedMembers: rtb != rtbNow");

            assertEq(
                pool.getTotalDisconnectedFlowRate(),
                actualDistributionFlowRate,
                "GDAv1.t.sol: pendingDistributionFlowRate != actualDistributionFlowRate"
            );
            (int256 memberClaimable,) = pool.getClaimableNow(member);
            assertEq(
                memberClaimable,
                (actualDistributionFlowRate * int96(int256(uint256(warpTime)))) * int96(uint96(members[i].newUnits))
                    / uint256(totalUnits).toInt256(),
                "GDAv1.t.sol: memberClaimable != (actualDistributionFlowRate * warpTime) / totalUnits"
            );
            assertEq(memberRTB, 0, "GDAv1.t.sol: memberRTB != 0");
            vm.prank(member);
            pool.claimAll();

            (memberRTB,,) = sf.gda.realtimeBalanceOf(superToken, member, block.timestamp);
            assertEq(memberRTB, memberClaimable, "GDAv1.t.sol: memberRTB != memberClaimable");
        }
    }

    // Pool ERC20 functions

    function testApproveOnly(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0));
        vm.assume(spender != address(0));

        _helperApprove(pool, owner, spender, amount);
    }

    function testIncreaseAllowance(address owner, address spender, uint256 addedValue) public {
        vm.assume(owner != address(0));
        vm.assume(spender != address(0));

        _helperIncreaseAllowance(pool, owner, spender, addedValue);
    }

    function testDecreaseAllowance(address owner, address spender, uint256 addedValue, uint256 subtractedValue)
        public
    {
        vm.assume(owner != address(0));
        vm.assume(spender != address(0));
        vm.assume(addedValue >= subtractedValue);

        _helperIncreaseAllowance(pool, owner, spender, addedValue);
        _helperDecreaseAllowance(pool, owner, spender, subtractedValue);
    }

    function testRevertIfUnitsTransferReceiverIsPool(address from, address to, int96 unitsAmount, int128 transferAmount)
        public
    {
        // @note we use int96 because overflow will happen otherwise
        vm.assume(unitsAmount >= 0);
        vm.assume(transferAmount > 0);
        vm.assume(from != address(0));
        vm.assume(to != address(0));
        vm.assume(from != to);
        vm.assume(transferAmount <= unitsAmount);
        _helperUpdateMemberUnits(pool, alice, from, uint128(int128(unitsAmount)));

        vm.startPrank(from);
        vm.expectRevert(ISuperfluidPool.SUPERFLUID_POOL_NO_POOL_MEMBERS.selector);
        pool.transfer(address(pool), uint256(uint128(transferAmount)));
        vm.stopPrank();
    }

    function testBasicTransfer(address from, address to, int96 unitsAmount, int128 transferAmount) public {
        // @note we use int96 because overflow will happen otherwise
        vm.assume(unitsAmount >= 0);
        vm.assume(transferAmount > 0);
        vm.assume(from != address(0));
        vm.assume(to != address(0));
        vm.assume(from != to);
        vm.assume(transferAmount <= unitsAmount);
        _helperUpdateMemberUnits(pool, alice, from, uint128(int128(unitsAmount)));

        _helperPoolUnitsTransfer(pool, from, to, uint256(uint128(transferAmount)));
    }

    function testApproveAndTransferFrom(address owner, address spender, int128 transferAmount) public {
        vm.assume(transferAmount > 0);
        vm.assume(spender != address(0));
        vm.assume(owner != address(0));
        vm.assume(spender != owner);
        _helperUpdateMemberUnits(pool, alice, owner, uint128(int128(transferAmount)));
        _helperApprove(pool, owner, spender, uint256(uint128(transferAmount)));
        _helperPoolUnitsTransferFrom(pool, spender, owner, spender, uint256(uint128(transferAmount)));
    }

    function testIncreaseAllowanceAndTransferFrom(address owner, address spender, int128 transferAmount) public {
        vm.assume(transferAmount > 0);
        vm.assume(spender != address(0));
        vm.assume(owner != address(0));
        vm.assume(spender != owner);
        _helperUpdateMemberUnits(pool, alice, owner, uint128(int128(transferAmount)));
        _helperIncreaseAllowance(pool, owner, spender, uint256(uint128(transferAmount)));
        _helperPoolUnitsTransferFrom(pool, spender, owner, spender, uint256(uint128(transferAmount)));
    }


    function testPoolRandomSeqs(PoolUpdateStep[20] memory steps) external {
        uint256 N_MEMBERS = 5;

        for (uint256 i = 0; i < steps.length; ++i) {
            emit log_named_uint(">>> STEP", i);
            PoolUpdateStep memory s = steps[i];
            uint256 action = s.a % 5;
            uint256 u = 1 + s.u % N_MEMBERS;
            address user = TEST_ACCOUNTS[u];

            emit log_named_uint("user", u);
            emit log_named_uint("time delta", s.dt);
            emit log_named_uint("> timestamp", block.timestamp);
            emit log_named_address("tester", user);

            if (action == 0) {
                emit log_named_string("action", "updateMember");
                emit log_named_uint("units", s.v);
                _helperUpdateMemberUnits(pool, pool.admin(), user, s.v);
            } else if (action == 1) {
                emit log_named_string("action", "distributeFlow");
                emit log_named_uint("flow rate", s.v);
                _helperDistributeFlow(superToken, user, user, pool, int96(uint96(s.v)));
            } else if (action == 2) {
                address u4 = TEST_ACCOUNTS[1 + (s.v % N_MEMBERS)];
                emit log_named_string("action", "claimAll");
                emit log_named_address("claim for", u4);
                vm.startPrank(user);
                assert(pool.claimAll(u4));
                vm.stopPrank();
            } else if (action == 3) {
                bool doConnect = s.v % 2 == 0 ? false : true;
                emit log_named_string("action", "doConnectPool");
                emit log_named_string("doConnect", doConnect ? "true" : "false");
                doConnect ? _helperConnectPool(user, superToken, pool) : _helperDisconnectPool(user, superToken, pool);
            } else if (action == 4) {
                // TODO uncomment this and it should work
                // emit log_named_string("action", "distribute");
                // emit log_named_uint("distributionAmount", s.v);
                // _helperDistribute(superToken, user, user, pool, uint256(s.v));
            } else {
                assert(false);
            }

            {
                (int256 own, int256 fromPools, int256 buffer) =
                    sf.gda.realtimeBalanceVectorAt(superToken, address(pool), block.timestamp);
                int96 connectedFlowRate = pool.getTotalConnectedFlowRate();
                int96 nr = sf.gda.getNetFlow(superToken, address(pool));
                emit log_string("> pool before time warp");
                emit log_named_int("own", own);
                emit log_named_int("fromPoolsBalance", fromPools);
                emit log_named_int("buffer", buffer);
                emit log_named_int("pool net flow rate", nr);
            }

            emit log_named_uint("> dt", s.dt);
            vm.warp(block.timestamp + s.dt);

            {
                (int256 own, int256 fromPools, int256 buffer) =
                    sf.gda.realtimeBalanceVectorAt(superToken, address(pool), block.timestamp);
                int96 connectedFlowRate = pool.getTotalConnectedFlowRate();
                int96 nr = sf.gda.getNetFlow(superToken, address(pool));
                emit log_string("> pool before time warp");
                emit log_named_int("own", own);
                emit log_named_int("fromPoolsBalance", fromPools);
                emit log_named_int("buffer", buffer);
                emit log_named_int("pool net flow rate", nr);
            }
        }

        int96 flowRatesSum;
        {
            (int256 own, int256 fromPools, int256 buffer) =
                sf.gda.realtimeBalanceVectorAt(superToken, address(pool), block.timestamp);
            int96 poolDisconnectedRate = pool.getTotalDisconnectedFlowRate();
            (,, int96 poolAdjustmentRate) = sf.gda.getPoolAdjustmentFlowInfo(pool);
            int96 poolNetFlowRate = sf.gda.getNetFlow(superToken, address(pool));
            flowRatesSum = flowRatesSum + poolNetFlowRate;
        }

        for (uint256 i = 1; i <= N_MEMBERS; ++i) {
            (int256 own, int256 fromPools, int256 buffer) =
                sf.gda.realtimeBalanceVectorAt(superToken, TEST_ACCOUNTS[i], block.timestamp);
            int96 flowRate = sf.gda.getNetFlow(superToken, TEST_ACCOUNTS[i]);
            flowRatesSum = flowRatesSum + flowRate;
        }

        assertEq(flowRatesSum, 0, "GDAv1.t: flowRatesSum != 0");
    }
}

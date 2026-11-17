// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StablePayEscrow} from "../src/StablePayEscrow.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal 6-decimal stablecoin stand-in for tests (NOT the real tUSD8).
contract MockUSD8 is ERC20 {
    constructor() ERC20("Test USD8", "tUSD8") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract StablePayEscrowTest is Test {
    StablePayEscrow internal escrow;
    MockUSD8 internal token;

    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal arbiter = makeAddr("arbiter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 10e6; // 10 tUSD8
    uint256 internal constant DEADLINE = 7 days;

    function setUp() public {
        token = new MockUSD8();
        escrow = new StablePayEscrow(token);
        token.mint(buyer, 1_000e6);
        vm.prank(buyer);
        token.approve(address(escrow), type(uint256).max);
    }

    function _createOrder() internal returns (uint256 orderId) {
        vm.prank(buyer);
        orderId = escrow.createOrder(seller, arbiter, AMOUNT, block.timestamp + DEADLINE);
    }

    function testCreateOrderLocksFunds() public {
        uint256 id = _createOrder();
        StablePayEscrow.Order memory o = escrow.getOrder(id);
        assertEq(uint256(o.state), uint256(StablePayEscrow.State.FUNDED));
        assertEq(o.buyer, buyer);
        assertEq(o.seller, seller);
        assertEq(o.amount, AMOUNT);
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(buyer), 1_000e6 - AMOUNT);
    }

    function testHappyPathDeliverAndConfirm() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.confirmDelivery(id);

        StablePayEscrow.Order memory o = escrow.getOrder(id);
        assertEq(uint256(o.state), uint256(StablePayEscrow.State.COMPLETED));
        assertEq(token.balanceOf(seller), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testCancelRefundsBuyerBeforeDelivery() public {
        uint256 id = _createOrder();
        vm.prank(buyer);
        escrow.cancelOrder(id);

        assertEq(uint256(escrow.getOrder(id).state), uint256(StablePayEscrow.State.REFUNDED));
        assertEq(token.balanceOf(buyer), 1_000e6);
    }

    function testRefundAfterDeadlineWithoutDelivery() public {
        uint256 id = _createOrder();
        vm.warp(block.timestamp + DEADLINE + 1);
        vm.prank(buyer);
        escrow.claimRefund(id);

        assertEq(uint256(escrow.getOrder(id).state), uint256(StablePayEscrow.State.REFUNDED));
        assertEq(token.balanceOf(buyer), 1_000e6);
    }

    function testRefundTooEarlyReverts() public {
        uint256 id = _createOrder();
        vm.prank(buyer);
        vm.expectRevert(StablePayEscrow.RefundNotAvailableYet.selector);
        escrow.claimRefund(id);
    }

    function testSellerAutoReleaseAfterConfirmWindow() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        // Buyer stays silent; after 3 days the seller claims the funds.
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(seller);
        escrow.claimRelease(id);

        assertEq(uint256(escrow.getOrder(id).state), uint256(StablePayEscrow.State.COMPLETED));
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function testDisputeResolvedToSeller() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.raiseDispute(id);
        vm.prank(arbiter);
        escrow.resolveDispute(id, true);

        assertEq(uint256(escrow.getOrder(id).state), uint256(StablePayEscrow.State.COMPLETED));
        assertEq(token.balanceOf(seller), AMOUNT);
    }

    function testDisputeResolvedToBuyer() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.raiseDispute(id);
        vm.prank(arbiter);
        escrow.resolveDispute(id, false);

        assertEq(uint256(escrow.getOrder(id).state), uint256(StablePayEscrow.State.REFUNDED));
        assertEq(token.balanceOf(buyer), 1_000e6);
    }

    function testOnlyBuyerCanConfirm() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(stranger);
        vm.expectRevert(StablePayEscrow.NotBuyer.selector);
        escrow.confirmDelivery(id);
    }

    function testOnlySellerCanMarkDelivered() public {
        uint256 id = _createOrder();
        vm.prank(buyer);
        vm.expectRevert(StablePayEscrow.NotSeller.selector);
        escrow.markDelivered(id);
    }

    function testOnlyArbiterResolvesDispute() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.raiseDispute(id);
        vm.prank(stranger);
        vm.expectRevert(StablePayEscrow.NotArbiter.selector);
        escrow.resolveDispute(id, true);
    }

    function testCreateOrderValidation() public {
        vm.startPrank(buyer);
        vm.expectRevert(StablePayEscrow.ZeroAmount.selector);
        escrow.createOrder(seller, arbiter, 0, block.timestamp + DEADLINE);
        vm.expectRevert(StablePayEscrow.SelfTrade.selector);
        escrow.createOrder(buyer, arbiter, AMOUNT, block.timestamp + DEADLINE);
        vm.expectRevert(StablePayEscrow.DeadlineInPast.selector);
        escrow.createOrder(seller, arbiter, AMOUNT, block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(
                StablePayEscrow.AmountExceedsCap.selector, 100_001e6, 100_000e6
            )
        );
        escrow.createOrder(seller, arbiter, 100_001e6, block.timestamp + DEADLINE);
        vm.stopPrank();
    }

    function testNoDisputeWithoutArbiter() public {
        vm.prank(buyer);
        uint256 id = escrow.createOrder(seller, address(0), AMOUNT, block.timestamp + DEADLINE);
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        vm.expectRevert(StablePayEscrow.NoArbiter.selector);
        escrow.raiseDispute(id);
    }

    function testCannotDoubleSpendCompletedOrder() public {
        uint256 id = _createOrder();
        vm.prank(seller);
        escrow.markDelivered(id);
        vm.prank(buyer);
        escrow.confirmDelivery(id);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(
                StablePayEscrow.WrongState.selector,
                StablePayEscrow.State.DELIVERED,
                StablePayEscrow.State.COMPLETED
            )
        );
        escrow.confirmDelivery(id);
    }
}

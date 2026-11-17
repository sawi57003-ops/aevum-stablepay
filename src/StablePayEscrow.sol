// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StablePayEscrow — escrowed stablecoin payments on Aevum testnet
/// @author Fngyuan (sawi57003-ops) — Aevum Builder Challenge #1
/// @notice One simple flow: a buyer locks tUSD8 in escrow, the seller marks the
///         order delivered, and funds move only when the buyer confirms delivery
///         (or an arbiter resolves a dispute, or a deadline expires).
///         The buyer never pays before delivery is confirmed; the seller is
///         protected by an auto-release once the confirmation window lapses.
/// @dev Written for Aevum testnet (chain 44005) with tUSD8
///      (0x456569838f1d43009A91ebA4263147Afd7233483, 6 decimals).
///      No owner, no upgradeability, no backdoor: every transition is enforced
///      by state + caller checks, and every transition emits an event so the
///      full audit trail is readable on the explorer.
contract StablePayEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Stablecoin held in escrow (tUSD8 on Aevum testnet).
    IERC20 public immutable token;

    /// @notice Maximum value of a single order (100,000 tUSD8). A spend cap:
    ///         no single order can lock more than this.
    uint256 public constant MAX_ORDER_AMOUNT = 100_000e6;

    /// @notice How long the buyer has to confirm or dispute after the seller
    ///         marks an order delivered. After this window the seller may claim
    ///         the funds (auto-release).
    uint256 public constant CONFIRM_WINDOW = 3 days;

    enum State {
        FUNDED, // buyer locked the funds
        DELIVERED, // seller marked the order delivered
        COMPLETED, // funds released to the seller
        REFUNDED, // funds returned to the buyer
        DISPUTED // buyer opened a dispute, waiting for the arbiter
    }

    struct Order {
        address buyer;
        address seller;
        address arbiter; // address(0) = no arbiter, no dispute path
        uint256 amount; // tUSD8, 6 decimals
        uint256 deliveryDeadline; // buyer may claim a refund after this if not delivered
        uint256 deliveredAt; // timestamp the seller marked delivery (0 if not yet)
        State state;
    }

    Order[] private _orders;

    event OrderCreated(
        uint256 indexed orderId,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 amount,
        uint256 deliveryDeadline
    );
    event OrderDelivered(uint256 indexed orderId, address indexed seller, uint256 deliveredAt);
    event OrderCompleted(uint256 indexed orderId, address indexed seller, uint256 amount);
    event OrderRefunded(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event DisputeRaised(uint256 indexed orderId, address indexed buyer);
    event DisputeResolved(uint256 indexed orderId, address indexed arbiter, bool releasedToSeller);

    error ZeroAddress();
    error ZeroAmount();
    error AmountExceedsCap(uint256 amount, uint256 cap);
    error DeadlineInPast();
    error DeadlineTooSoon(uint256 deadline, uint256 earliest);
    error SelfTrade();
    error ArbiterIsBuyer();
    error OrderNotFound(uint256 orderId);
    error NotBuyer();
    error NotSeller();
    error NotArbiter();
    error NoArbiter();
    error WrongState(State expected, State actual);
    error DeliveryWindowOver();
    error RefundNotAvailableYet();

    /// @param token_ The stablecoin to escrow (tUSD8 on Aevum testnet).
    constructor(IERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @notice Total number of orders ever created.
    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    /// @notice Read one order by id.
    function getOrder(uint256 orderId) external view returns (Order memory) {
        if (orderId >= _orders.length) revert OrderNotFound(orderId);
        return _orders[orderId];
    }

    /// @notice Create an order and lock `amount` tUSD8 in escrow.
    /// @dev The buyer must approve this contract for `amount` first.
    /// @param seller Who gets paid once delivery is confirmed.
    /// @param arbiter Neutral third party that resolves disputes, or address(0)
    ///        for no dispute path (buyer then relies on confirm / refund only).
    /// @param amount tUSD8 to lock (6 decimals, > 0, <= MAX_ORDER_AMOUNT).
    /// @param deliveryDeadline Unix timestamp; the buyer may claim a refund
    ///        after this time if the seller never marks delivery. Must be at
    ///        least 1 hour in the future.
    /// @return orderId The new order's id.
    function createOrder(address seller, address arbiter, uint256 amount, uint256 deliveryDeadline)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (seller == address(0)) revert ZeroAddress();
        if (arbiter == msg.sender) revert ArbiterIsBuyer();
        if (seller == msg.sender) revert SelfTrade();
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_ORDER_AMOUNT) revert AmountExceedsCap(amount, MAX_ORDER_AMOUNT);
        if (deliveryDeadline <= block.timestamp) revert DeadlineInPast();
        if (deliveryDeadline < block.timestamp + 1 hours) {
            revert DeadlineTooSoon(deliveryDeadline, block.timestamp + 1 hours);
        }

        orderId = _orders.length;
        _orders.push(
            Order({
                buyer: msg.sender,
                seller: seller,
                arbiter: arbiter,
                amount: amount,
                deliveryDeadline: deliveryDeadline,
                deliveredAt: 0,
                state: State.FUNDED
            })
        );

        // Pull the funds first; state is already FUNDED before the transfer,
        // and the whole call is non-reentrant.
        token.safeTransferFrom(msg.sender, address(this), amount);

        emit OrderCreated(orderId, msg.sender, seller, arbiter, amount, deliveryDeadline);
    }

    /// @notice Seller marks the order delivered. Starts the confirmation window.
    function markDelivered(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.seller) revert NotSeller();
        if (order.state != State.FUNDED) revert WrongState(State.FUNDED, order.state);
        if (block.timestamp > order.deliveryDeadline) revert DeliveryWindowOver();

        order.state = State.DELIVERED;
        order.deliveredAt = block.timestamp;

        emit OrderDelivered(orderId, msg.sender, block.timestamp);
    }

    /// @notice Buyer confirms delivery. Funds are released to the seller.
    function confirmDelivery(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.buyer) revert NotBuyer();
        if (order.state != State.DELIVERED) revert WrongState(State.DELIVERED, order.state);

        order.state = State.COMPLETED;
        token.safeTransfer(order.seller, order.amount);

        emit OrderCompleted(orderId, order.seller, order.amount);
    }

    /// @notice Buyer cancels an order that was never marked delivered.
    ///         Funds return to the buyer in full.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.buyer) revert NotBuyer();
        if (order.state != State.FUNDED) revert WrongState(State.FUNDED, order.state);

        order.state = State.REFUNDED;
        token.safeTransfer(order.buyer, order.amount);

        emit OrderRefunded(orderId, order.buyer, order.amount);
    }

    /// @notice Buyer reclaims the funds when the delivery deadline passed
    ///         without the seller marking delivery.
    function claimRefund(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.buyer) revert NotBuyer();
        if (order.state != State.FUNDED) revert WrongState(State.FUNDED, order.state);
        if (block.timestamp <= order.deliveryDeadline) revert RefundNotAvailableYet();

        order.state = State.REFUNDED;
        token.safeTransfer(order.buyer, order.amount);

        emit OrderRefunded(orderId, order.buyer, order.amount);
    }

    /// @notice Seller claims the funds after the buyer stayed silent for the
    ///         whole confirmation window following delivery.
    function claimRelease(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.seller) revert NotSeller();
        if (order.state != State.DELIVERED) revert WrongState(State.DELIVERED, order.state);
        if (block.timestamp <= order.deliveredAt + CONFIRM_WINDOW) {
            revert RefundNotAvailableYet();
        }

        order.state = State.COMPLETED;
        token.safeTransfer(order.seller, order.amount);

        emit OrderCompleted(orderId, order.seller, order.amount);
    }

    /// @notice Buyer opens a dispute after delivery was marked but before
    ///         confirming. Only possible while the confirmation window is open
    ///         and an arbiter was set at creation.
    function raiseDispute(uint256 orderId) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.buyer) revert NotBuyer();
        if (order.state != State.DELIVERED) revert WrongState(State.DELIVERED, order.state);
        if (order.arbiter == address(0)) revert NoArbiter();
        if (block.timestamp > order.deliveredAt + CONFIRM_WINDOW) {
            revert DeliveryWindowOver();
        }

        order.state = State.DISPUTED;

        emit DisputeRaised(orderId, msg.sender);
    }

    /// @notice Arbiter settles a dispute: release the funds to the seller
    ///         (delivery accepted) or refund them to the buyer.
    function resolveDispute(uint256 orderId, bool releaseToSeller) external nonReentrant {
        Order storage order = _order(orderId);
        if (msg.sender != order.arbiter) revert NotArbiter();
        if (order.state != State.DISPUTED) revert WrongState(State.DISPUTED, order.state);

        if (releaseToSeller) {
            order.state = State.COMPLETED;
            token.safeTransfer(order.seller, order.amount);
            emit DisputeResolved(orderId, msg.sender, true);
            emit OrderCompleted(orderId, order.seller, order.amount);
        } else {
            order.state = State.REFUNDED;
            token.safeTransfer(order.buyer, order.amount);
            emit DisputeResolved(orderId, msg.sender, false);
            emit OrderRefunded(orderId, order.buyer, order.amount);
        }
    }

    function _order(uint256 orderId) private view returns (Order storage) {
        if (orderId >= _orders.length) revert OrderNotFound(orderId);
        return _orders[orderId];
    }
}

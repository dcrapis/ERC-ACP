// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../BaseACPHook.sol";

/**
 * @title AuctionHook
 * @notice Example ACP hook that manages a sealed-bid auction for provider selection.
 *
 * USE CASE
 * --------
 * A client wants to hire the best (or cheapest) agent for a job but does not
 * know upfront who to assign. The job is created with no provider, and this
 * hook manages a bidding window. Once closed, the client calls setProvider
 * with the winning address; the hook validates the winner and finalises the
 * auction — preventing the client from picking an arbitrary address.
 *
 * FLOW (hook callbacks marked with →)
 * ----
 *  1. createJob(provider=0, evaluator, expiredAt, description, hook=this)
 *  2. Client calls openAuction(jobId, deadline) on this hook.
 *  3. Bidders call placeBid(jobId, amount) during the bidding window.
 *  4. After deadline, client calls closeAuction(jobId). Winner determined.
 *  5. Client calls setProvider(jobId, winner, ""):
 *     → _preSetProvider: validates address == auction winner. Reverts if not.
 *     → AgenticCommerceHooked: sets job.provider = winner.
 *     → _postSetProvider: marks auction as finalised.
 *  6. Job continues normally: setBudget → fund → submit → complete.
 *
 * NOTE: openAuction, placeBid, closeAuction are direct calls to this hook
 * (the auction system), not ACP callbacks. The hook callbacks only fire at
 * setProvider to enforce the auction outcome.
 */
contract AuctionHook is BaseACPHook {

    struct Auction {
        uint256 deadline;
        bool closed;
        bool finalised;
        address winner;
        uint256 winningBid;
    }

    struct Bid {
        address bidder;
        uint256 amount;
    }

    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Bid[]) public bids;

    error OnlyClient();
    error AuctionNotOpen();
    error AuctionStillOpen();
    error AuctionAlreadyClosed();
    error AuctionNotClosed();
    error AuctionAlreadyFinalised();
    error NotTheWinner();
    error NoBids();
    error DeadlineMustBeFuture();

    constructor(address acpContract_) BaseACPHook(acpContract_) {}

    // -------------------------------------------------------------------------
    // Auction management (called directly by client / bidders)
    // -------------------------------------------------------------------------

    function openAuction(uint256 jobId, uint256 deadline) external {
        _assertClient(jobId);
        if (deadline <= block.timestamp) revert DeadlineMustBeFuture();
        if (auctions[jobId].deadline != 0) revert AuctionAlreadyClosed();
        auctions[jobId] = Auction({
            deadline: deadline,
            closed: false,
            finalised: false,
            winner: address(0),
            winningBid: type(uint256).max
        });
    }

    function placeBid(uint256 jobId, uint256 amount) external {
        Auction storage a = auctions[jobId];
        if (a.deadline == 0 || a.closed) revert AuctionNotOpen();
        if (block.timestamp >= a.deadline) revert AuctionStillOpen();
        bids[jobId].push(Bid({bidder: msg.sender, amount: amount}));
    }

    function closeAuction(uint256 jobId) external {
        _assertClient(jobId);
        Auction storage a = auctions[jobId];
        if (a.deadline == 0) revert AuctionNotOpen();
        if (a.closed) revert AuctionAlreadyClosed();
        if (block.timestamp < a.deadline) revert AuctionStillOpen();
        if (bids[jobId].length == 0) revert NoBids();

        a.closed = true;

        Bid[] storage b = bids[jobId];
        address winner = b[0].bidder;
        uint256 winningBid = b[0].amount;
        for (uint256 i = 1; i < b.length; i++) {
            if (b[i].amount < winningBid) {
                winningBid = b[i].amount;
                winner = b[i].bidder;
            }
        }
        a.winner = winner;
        a.winningBid = winningBid;
    }

    // -------------------------------------------------------------------------
    // Hook callbacks (called by AgenticCommerceHooked via beforeAction/afterAction)
    // -------------------------------------------------------------------------

    function _preSetProvider(uint256 jobId, address provider_, bytes memory) internal override {
        Auction storage a = auctions[jobId];
        if (!a.closed) revert AuctionNotClosed();
        if (a.finalised) revert AuctionAlreadyFinalised();
        if (provider_ != a.winner) revert NotTheWinner();
    }

    function _postSetProvider(uint256 jobId, address, bytes memory) internal override {
        auctions[jobId].finalised = true;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function getBids(uint256 jobId) external view returns (Bid[] memory) {
        return bids[jobId];
    }

    function _assertClient(uint256 jobId) internal view {
        address client = _getJobClient(jobId);
        if (msg.sender != client) revert OnlyClient();
    }
}

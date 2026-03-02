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
 * ROLES
 * -----
 *  - Client: creates the job (provider = address(0)), opens the auction.
 *  - Bidders (agents): call placeBid on this hook during the bidding window.
 *  - Client: calls closeAuction to lock in the winner, then calls setProvider
 *    on ACPMinimal with the winner address.
 *  - ACP hook: preSetProvider validates the address matches the auction winner.
 *    postSetProvider marks the auction as finalised.
 *
 * FLOW
 * ----
 *  1. createJob(provider=0, evaluator, expiredAt, description, hook=this)
 *     └─ Job created in Open state with no provider.
 *        Client calls openAuction(jobId, deadline) on this hook.
 *
 *  2. Bidders call placeBid(jobId) during the bidding window.
 *     └─ Hook records each bid (bidder address + bid amount).
 *        (In this example bids are a simple lowest-price-wins ranking;
 *         other auction types are straightforward extensions.)
 *
 *  3. After deadline, client calls closeAuction(jobId).
 *     └─ Hook picks the lowest bidder as winner and stores winnerFor[jobId].
 *
 *  4. setProvider(jobId, winner, optParams: "")   [called by client on ACPMinimal]
 *     └─ preSetProvider:  validate provider_ == winnerFor[jobId]. Revert if not.
 *     └─ ACPMinimal:      set job.provider = winner.
 *     └─ postSetProvider: mark auction as finalised.
 *
 *  5. Job continues normally: setBudget → fund → submit → complete.
 *
 * SECURITY NOTES
 * --------------
 *  - Only the client may open or close an auction (enforced here).
 *  - preSetProvider enforces the winner — the client cannot assign a random address.
 *  - Bids are publicly visible on-chain; for sealed bids, use a commit-reveal
 *    extension (not shown here, to keep the example minimal).
 *  - A real auction would also handle bid deposits and refunds.
 */
contract AuctionHook is BaseACPHook {

    struct Auction {
        uint256 deadline;
        bool closed;
        bool finalised;
        address winner;
        uint256 winningBid; // lowest bid amount wins
    }

    struct Bid {
        address bidder;
        uint256 amount;
    }

    address public immutable acpMinimal;

    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => Bid[]) public bids;

    error OnlyACPMinimal();
    error OnlyClient();
    error AuctionNotOpen();
    error AuctionStillOpen();
    error AuctionAlreadyClosed();
    error AuctionNotClosed();
    error AuctionAlreadyFinalised();
    error NotTheWinner();
    error NoBids();
    error ZeroAddress();
    error DeadlineMustBeFuture();

    modifier onlyACP() {
        if (msg.sender != acpMinimal) revert OnlyACPMinimal();
        _;
    }

    constructor(address acpMinimal_) {
        if (acpMinimal_ == address(0)) revert ZeroAddress();
        acpMinimal = acpMinimal_;
    }

    // -------------------------------------------------------------------------
    // Auction management (called directly by client / bidders)
    // -------------------------------------------------------------------------

    /**
     * @notice Client opens a bidding window for a job.
     * @param jobId   The ACP job ID.
     * @param deadline Unix timestamp after which no more bids are accepted.
     */
    function openAuction(uint256 jobId, uint256 deadline) external {
        _assertClient(jobId);
        if (deadline <= block.timestamp) revert DeadlineMustBeFuture();
        if (auctions[jobId].deadline != 0) revert AuctionAlreadyClosed(); // already opened
        auctions[jobId] = Auction({
            deadline: deadline,
            closed: false,
            finalised: false,
            winner: address(0),
            winningBid: type(uint256).max
        });
    }

    /**
     * @notice Bidder places a bid. Lower amount = more competitive.
     * @param jobId     The ACP job ID.
     * @param amount    Bid amount (e.g. the fee the bidder will accept).
     */
    function placeBid(uint256 jobId, uint256 amount) external {
        Auction storage a = auctions[jobId];
        if (a.deadline == 0 || a.closed) revert AuctionNotOpen();
        if (block.timestamp >= a.deadline) revert AuctionStillOpen();
        bids[jobId].push(Bid({bidder: msg.sender, amount: amount}));
    }

    /**
     * @notice Client closes the auction and picks the lowest bidder as winner.
     * @param jobId The ACP job ID.
     */
    function closeAuction(uint256 jobId) external {
        _assertClient(jobId);
        Auction storage a = auctions[jobId];
        if (a.deadline == 0) revert AuctionNotOpen();
        if (a.closed) revert AuctionAlreadyClosed();
        if (block.timestamp < a.deadline) revert AuctionStillOpen();
        if (bids[jobId].length == 0) revert NoBids();

        a.closed = true;

        // Pick winner: lowest bid amount.
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
    // IACPHook callbacks
    // -------------------------------------------------------------------------

    /**
     * @notice Called by ACPMinimal before setProvider.
     *         Validates that the proposed provider is the auction winner.
     */
    function preSetProvider(uint256 jobId, address provider, bytes calldata) external override onlyACP {
        Auction storage a = auctions[jobId];
        if (!a.closed) revert AuctionNotClosed();
        if (a.finalised) revert AuctionAlreadyFinalised();
        if (provider != a.winner) revert NotTheWinner();
    }

    /**
     * @notice Called by ACPMinimal after setProvider.
     *         Marks the auction as finalised — no further setProvider calls allowed.
     */
    function postSetProvider(uint256 jobId, address, bytes calldata) external override onlyACP {
        auctions[jobId].finalised = true;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function getBids(uint256 jobId) external view returns (Bid[] memory) {
        return bids[jobId];
    }

    function _assertClient(uint256 jobId) internal view {
        (bool ok, bytes memory data) = acpMinimal.staticcall(
            abi.encodeWithSignature("getJob(uint256)", jobId)
        );
        require(ok, "getJob failed");
        (, address client,,,,,,,,) = abi.decode(
            data, (uint256, address, address, address, address, string, uint256, uint256, uint8, bool)
        );
        if (msg.sender != client) revert OnlyClient();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract SettlementQueue {
    enum TicketStatus {
        None,
        Pending,
        Ready,
        Consumed,
        Cancelled
    }

    struct SettlementTicket {
        bytes32 id;
        address accountOwner;
        uint256 subAccountId;
        bytes32 marketId;
        bytes32 asset;
        int256 sizeDelta;
        uint256 notionalValue;
        uint256 collateralValue;
        uint256 debtValue;
        uint256 validAfter;
        uint256 expiresAt;
        uint256 createdAt;
        TicketStatus status;
    }

    struct QueueStats {
        uint256 pending;
        uint256 ready;
        uint256 consumed;
        uint256 cancelled;
        uint256 expired;
    }

    address public immutable coordinator;
    uint256 public nextSequence = 1;
    uint256 public minDelay = 1;
    uint256 public maxTtl = 30 minutes;

    mapping(bytes32 => SettlementTicket) private _tickets;
    mapping(address => bytes32[]) private _ownerTickets;
    bytes32[] private _ticketIds;

    event TicketCreated(
        bytes32 indexed ticketId,
        address indexed accountOwner,
        uint256 indexed subAccountId,
        bytes32 marketId,
        uint256 notionalValue,
        uint256 validAfter,
        uint256 expiresAt
    );
    event TicketReady(bytes32 indexed ticketId);
    event TicketConsumed(bytes32 indexed ticketId, address indexed executor);
    event TicketCancelled(bytes32 indexed ticketId, address indexed caller);
    event QueueTimingUpdated(uint256 minDelay, uint256 maxTtl);

    error NotCoordinator();
    error TicketMissing(bytes32 ticketId);
    error TicketNotPending(bytes32 ticketId);
    error TicketNotReady(bytes32 ticketId);
    error TicketExpired(bytes32 ticketId);
    error InvalidTiming();
    error ZeroAddress();
    error ZeroAmount();

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert NotCoordinator();
        _;
    }

    constructor(address coordinator_) {
        if (coordinator_ == address(0)) revert ZeroAddress();
        coordinator = coordinator_;
    }

    function configureTiming(uint256 minDelay_, uint256 maxTtl_) external onlyCoordinator {
        if (maxTtl_ == 0 || minDelay_ > maxTtl_) revert InvalidTiming();
        minDelay = minDelay_;
        maxTtl = maxTtl_;
        emit QueueTimingUpdated(minDelay_, maxTtl_);
    }

    function createTicket(
        address accountOwner,
        uint256 subAccountId,
        bytes32 marketId,
        bytes32 asset,
        int256 sizeDelta,
        uint256 notionalValue,
        uint256 collateralValue,
        uint256 debtValue
    ) external onlyCoordinator returns (bytes32 ticketId) {
        if (accountOwner == address(0)) revert ZeroAddress();
        if (notionalValue == 0 && collateralValue == 0 && debtValue == 0) revert ZeroAmount();

        uint256 sequence = nextSequence++;
        uint256 validAfter = block.timestamp + minDelay;
        uint256 expiresAt = block.timestamp + maxTtl;
        ticketId = keccak256(
            abi.encode(
                address(this),
                block.chainid,
                sequence,
                accountOwner,
                subAccountId,
                marketId,
                asset,
                sizeDelta,
                notionalValue,
                collateralValue,
                debtValue
            )
        );

        _tickets[ticketId] = SettlementTicket({
            id: ticketId,
            accountOwner: accountOwner,
            subAccountId: subAccountId,
            marketId: marketId,
            asset: asset,
            sizeDelta: sizeDelta,
            notionalValue: notionalValue,
            collateralValue: collateralValue,
            debtValue: debtValue,
            validAfter: validAfter,
            expiresAt: expiresAt,
            createdAt: block.timestamp,
            status: TicketStatus.Pending
        });
        _ticketIds.push(ticketId);
        _ownerTickets[accountOwner].push(ticketId);
        emit TicketCreated(
            ticketId,
            accountOwner,
            subAccountId,
            marketId,
            notionalValue,
            validAfter,
            expiresAt
        );
    }

    function markReady(bytes32 ticketId) external onlyCoordinator {
        SettlementTicket storage ticket = _requireTicket(ticketId);
        if (ticket.status != TicketStatus.Pending) revert TicketNotPending(ticketId);
        if (block.timestamp > ticket.expiresAt) revert TicketExpired(ticketId);
        if (block.timestamp < ticket.validAfter) revert TicketNotReady(ticketId);
        ticket.status = TicketStatus.Ready;
        emit TicketReady(ticketId);
    }

    function consume(
        bytes32 ticketId
    ) external onlyCoordinator returns (SettlementTicket memory ticket) {
        SettlementTicket storage stored = _requireTicket(ticketId);
        if (stored.status == TicketStatus.Pending && block.timestamp >= stored.validAfter) {
            stored.status = TicketStatus.Ready;
            emit TicketReady(ticketId);
        }
        if (stored.status != TicketStatus.Ready) revert TicketNotReady(ticketId);
        if (block.timestamp > stored.expiresAt) revert TicketExpired(ticketId);
        stored.status = TicketStatus.Consumed;
        ticket = stored;
        emit TicketConsumed(ticketId, msg.sender);
    }

    function cancel(bytes32 ticketId) external onlyCoordinator {
        SettlementTicket storage ticket = _requireTicket(ticketId);
        if (ticket.status != TicketStatus.Pending && ticket.status != TicketStatus.Ready) {
            revert TicketNotPending(ticketId);
        }
        ticket.status = TicketStatus.Cancelled;
        emit TicketCancelled(ticketId, msg.sender);
    }

    function expire(bytes32 ticketId) external {
        SettlementTicket storage ticket = _requireTicket(ticketId);
        if (ticket.status != TicketStatus.Pending && ticket.status != TicketStatus.Ready) {
            revert TicketNotPending(ticketId);
        }
        if (block.timestamp <= ticket.expiresAt) revert TicketNotReady(ticketId);
        ticket.status = TicketStatus.Cancelled;
        emit TicketCancelled(ticketId, msg.sender);
    }

    function getTicket(bytes32 ticketId) external view returns (SettlementTicket memory) {
        return _tickets[ticketId];
    }

    function ticketIds() external view returns (bytes32[] memory) {
        return _ticketIds;
    }

    function ownerTickets(address accountOwner) external view returns (bytes32[] memory) {
        return _ownerTickets[accountOwner];
    }

    function queueStats() external view returns (QueueStats memory stats) {
        for (uint256 i = 0; i < _ticketIds.length; i++) {
            SettlementTicket storage ticket = _tickets[_ticketIds[i]];
            if (ticket.status == TicketStatus.Pending) {
                if (block.timestamp > ticket.expiresAt) {
                    stats.expired += 1;
                } else {
                    stats.pending += 1;
                }
            } else if (ticket.status == TicketStatus.Ready) {
                if (block.timestamp > ticket.expiresAt) {
                    stats.expired += 1;
                } else {
                    stats.ready += 1;
                }
            } else if (ticket.status == TicketStatus.Consumed) {
                stats.consumed += 1;
            } else if (ticket.status == TicketStatus.Cancelled) {
                stats.cancelled += 1;
            }
        }
    }

    function pendingTickets(address accountOwner) external view returns (bytes32[] memory ids) {
        bytes32[] memory all = _ownerTickets[accountOwner];
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            TicketStatus status = _tickets[all[i]].status;
            if (status == TicketStatus.Pending || status == TicketStatus.Ready) {
                count += 1;
            }
        }
        ids = new bytes32[](count);
        uint256 cursor;
        for (uint256 i = 0; i < all.length; i++) {
            TicketStatus status = _tickets[all[i]].status;
            if (status == TicketStatus.Pending || status == TicketStatus.Ready) {
                ids[cursor++] = all[i];
            }
        }
    }

    function executableTickets(address accountOwner) external view returns (bytes32[] memory ids) {
        bytes32[] memory all = _ownerTickets[accountOwner];
        uint256 count;
        for (uint256 i = 0; i < all.length; i++) {
            SettlementTicket storage ticket = _tickets[all[i]];
            if (
                (ticket.status == TicketStatus.Pending || ticket.status == TicketStatus.Ready) &&
                block.timestamp >= ticket.validAfter &&
                block.timestamp <= ticket.expiresAt
            ) {
                count += 1;
            }
        }
        ids = new bytes32[](count);
        uint256 cursor;
        for (uint256 i = 0; i < all.length; i++) {
            SettlementTicket storage ticket = _tickets[all[i]];
            if (
                (ticket.status == TicketStatus.Pending || ticket.status == TicketStatus.Ready) &&
                block.timestamp >= ticket.validAfter &&
                block.timestamp <= ticket.expiresAt
            ) {
                ids[cursor++] = all[i];
            }
        }
    }

    function isExecutable(bytes32 ticketId) external view returns (bool) {
        SettlementTicket storage ticket = _tickets[ticketId];
        return
            ticket.status != TicketStatus.None &&
            (ticket.status == TicketStatus.Pending || ticket.status == TicketStatus.Ready) &&
            block.timestamp >= ticket.validAfter &&
            block.timestamp <= ticket.expiresAt;
    }

    function _requireTicket(
        bytes32 ticketId
    ) internal view returns (SettlementTicket storage ticket) {
        ticket = _tickets[ticketId];
        if (ticket.status == TicketStatus.None) revert TicketMissing(ticketId);
    }
}

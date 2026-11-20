// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  UrbanMoveTaxi
 * @author Tsolmon Jargalsaikhan (2024520) - CCT College Dublin
 * @notice CA2 - Distributed Digital Transactions.
 *         Prototype smart contract for UrbanMove Taxi Services that automates
 *         driver verification, taxi booking, fare escrow and payment release
 *         between a passenger and a taxi driver.
 *
 * Smart contract design principles (Szabo) reflected in this code:
 *  - Observability   : every state change emits an event; public getters let
 *                      passengers, drivers and UrbanMove inspect each ride.
 *  - Verifiability   : a strict ride state machine (require checks) proves each
 *                      step happened in the correct order.
 *  - Privity         : role modifiers (onlyAdmin / onlyRidePassenger /
 *                      onlyRideDriver) limit who can act on a ride; only hashes
 *                      of licences and locations are stored (GDPR minimisation).
 *  - Enforceability  : the fare is locked in escrow and released automatically;
 *                      the driver can claim it if the passenger does not respond.
 */
contract UrbanMoveTaxi {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------
    enum DriverStatus { None, Pending, Verified, Suspended }

    enum RideStatus {
        None,        // 0
        Requested,   // 1 passenger booked and paid fare into escrow
        Accepted,    // 2 verified driver accepted the booking
        InProgress,  // 3 passenger picked up
        Completed,   // 4 driver marked journey as finished
        Paid,        // 5 fare released to driver
        Cancelled,   // 6 booking cancelled and refunded
        Disputed,    // 7 passenger raised a dispute
        Resolved     // 8 UrbanMove resolved the dispute
    }

    struct Driver {
        DriverStatus status;
        bytes32 licenceHash;     // hash of SPSV licence reference (no personal data)
        uint256 completedRides;
        uint256 ratingTotal;
        uint256 ratingCount;
    }

    struct Ride {
        uint256 id;
        address payable passenger;
        address payable driver;
        uint256 fare;            // wei held in escrow by this contract
        bytes32 pickupHash;      // hashed pickup location (privacy by design)
        bytes32 dropoffHash;     // hashed drop-off location
        RideStatus status;
        uint256 requestedAt;
        uint256 completedAt;
        bool rated;
    }

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------
    address payable public immutable admin;               // UrbanMove Taxi Services
    uint256 public constant PLATFORM_FEE_PERCENT = 10;    // UrbanMove commission
    uint256 public constant CANCELLATION_FEE_PERCENT = 10;// paid to driver on late cancel
    uint256 public constant CONFIRMATION_WINDOW = 2 minutes;

    uint256 public rideCount;
    bool public paused;
    bool private locked;

    mapping(address => Driver) public drivers;
    mapping(uint256 => Ride) public rides;

    // ------------------------------------------------------------------
    // Events (observability / audit trail)
    // ------------------------------------------------------------------
    event DriverRegistered(address indexed driver, bytes32 licenceHash);
    event DriverVerified(address indexed driver);
    event DriverSuspended(address indexed driver);
    event RideRequested(uint256 indexed rideId, address indexed passenger, uint256 fare);
    event RideAccepted(uint256 indexed rideId, address indexed driver);
    event RideStarted(uint256 indexed rideId, uint256 timestamp);
    event RideCompleted(uint256 indexed rideId, uint256 timestamp);
    event PaymentReleased(uint256 indexed rideId, address indexed driver, uint256 driverAmount, uint256 platformFee, bool claimedByDriver);
    event RideCancelled(uint256 indexed rideId, address indexed cancelledBy, uint256 refund, uint256 cancellationFee);
    event DisputeRaised(uint256 indexed rideId, address indexed passenger);
    event DisputeResolved(uint256 indexed rideId, uint256 driverAmount, uint256 passengerRefund);
    event DriverRated(address indexed driver, uint256 indexed rideId, uint8 stars);
    event PausedStateChanged(bool paused);

    // ------------------------------------------------------------------
    // Modifiers (privity / access control)
    // ------------------------------------------------------------------
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only UrbanMove admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Bookings are paused");
        _;
    }

    modifier rideExists(uint256 rideId) {
        require(rideId > 0 && rideId <= rideCount, "Ride does not exist");
        _;
    }

    modifier onlyRidePassenger(uint256 rideId) {
        require(msg.sender == rides[rideId].passenger, "Only the ride passenger");
        _;
    }

    modifier onlyRideDriver(uint256 rideId) {
        require(msg.sender == rides[rideId].driver, "Only the assigned driver");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "Reentrant call");
        locked = true;
        _;
        locked = false;
    }

    constructor() {
        admin = payable(msg.sender);
    }

    // ------------------------------------------------------------------
    // Driver management
    // ------------------------------------------------------------------
    /// @notice Driver submits a hash of their SPSV licence for verification.
    function registerDriver(bytes32 licenceHash) external {
        require(msg.sender != admin, "Admin cannot register as driver");
        require(drivers[msg.sender].status == DriverStatus.None, "Driver already registered");
        require(licenceHash != bytes32(0), "Licence hash required");

        drivers[msg.sender].status = DriverStatus.Pending;
        drivers[msg.sender].licenceHash = licenceHash;
        emit DriverRegistered(msg.sender, licenceHash);
    }

    /// @notice UrbanMove verifies a driver after off-chain licence checks.
    function verifyDriver(address driver) external onlyAdmin {
        DriverStatus s = drivers[driver].status;
        require(s == DriverStatus.Pending || s == DriverStatus.Suspended, "Driver not pending or suspended");
        drivers[driver].status = DriverStatus.Verified;
        emit DriverVerified(driver);
    }

    /// @notice UrbanMove suspends a driver (e.g. expired licence, complaints).
    function suspendDriver(address driver) external onlyAdmin {
        require(drivers[driver].status == DriverStatus.Verified, "Driver not verified");
        drivers[driver].status = DriverStatus.Suspended;
        emit DriverSuspended(driver);
    }

    // ------------------------------------------------------------------
    // Booking lifecycle
    // ------------------------------------------------------------------
    /// @notice Passenger books a taxi and locks the agreed fare in escrow.
    function requestRide(bytes32 pickupHash, bytes32 dropoffHash)
        external
        payable
        whenNotPaused
        returns (uint256 rideId)
    {
        require(msg.value > 0, "Fare must be greater than zero");
        require(pickupHash != bytes32(0) && dropoffHash != bytes32(0), "Location hashes required");

        rideId = ++rideCount;
        rides[rideId] = Ride({
            id: rideId,
            passenger: payable(msg.sender),
            driver: payable(address(0)),
            fare: msg.value,
            pickupHash: pickupHash,
            dropoffHash: dropoffHash,
            status: RideStatus.Requested,
            requestedAt: block.timestamp,
            completedAt: 0,
            rated: false
        });
        emit RideRequested(rideId, msg.sender, msg.value);
    }

    /// @notice A verified driver accepts an open booking.
    function acceptRide(uint256 rideId) external whenNotPaused rideExists(rideId) {
        Ride storage r = rides[rideId];
        require(drivers[msg.sender].status == DriverStatus.Verified, "Only verified drivers");
        require(r.status == RideStatus.Requested, "Ride not available");
        require(msg.sender != r.passenger, "Passenger cannot drive own ride");

        r.driver = payable(msg.sender);
        r.status = RideStatus.Accepted;
        emit RideAccepted(rideId, msg.sender);
    }

    /// @notice Driver confirms the passenger has been picked up.
    function startRide(uint256 rideId) external rideExists(rideId) onlyRideDriver(rideId) {
        Ride storage r = rides[rideId];
        require(r.status == RideStatus.Accepted, "Ride not accepted");
        r.status = RideStatus.InProgress;
        emit RideStarted(rideId, block.timestamp);
    }

    /// @notice Driver marks the journey as finished at the destination.
    function completeRide(uint256 rideId) external rideExists(rideId) onlyRideDriver(rideId) {
        Ride storage r = rides[rideId];
        require(r.status == RideStatus.InProgress, "Ride not in progress");
        r.status = RideStatus.Completed;
        r.completedAt = block.timestamp;
        emit RideCompleted(rideId, block.timestamp);
    }

    // ------------------------------------------------------------------
    // Payment release
    // ------------------------------------------------------------------
    /// @notice Passenger confirms arrival; fare is released to the driver.
    function confirmAndPay(uint256 rideId)
        external
        nonReentrant
        rideExists(rideId)
        onlyRidePassenger(rideId)
    {
        require(rides[rideId].status == RideStatus.Completed, "Ride not completed");
        _releasePayment(rideId, false);
    }

    /// @notice If the passenger does not respond, the driver can claim the fare
    ///         once the confirmation window has passed (self-enforcing payment).
    function claimPayment(uint256 rideId)
        external
        nonReentrant
        rideExists(rideId)
        onlyRideDriver(rideId)
    {
        Ride storage r = rides[rideId];
        require(r.status == RideStatus.Completed, "Ride not completed");
        require(block.timestamp >= r.completedAt + CONFIRMATION_WINDOW, "Confirmation window still open");
        _releasePayment(rideId, true);
    }

    // ------------------------------------------------------------------
    // Cancellation and disputes
    // ------------------------------------------------------------------
    /// @notice Cancel before the journey starts.
    ///         Requested -> passenger gets full refund.
    ///         Accepted  -> passenger cancels: 10% fee to driver, rest refunded;
    ///                      driver cancels: passenger gets full refund.
    function cancelRide(uint256 rideId) external nonReentrant rideExists(rideId) {
        Ride storage r = rides[rideId];
        uint256 refund;
        uint256 fee;

        if (r.status == RideStatus.Requested) {
            require(msg.sender == r.passenger, "Only the ride passenger");
            refund = r.fare;
        } else if (r.status == RideStatus.Accepted) {
            require(msg.sender == r.passenger || msg.sender == r.driver, "Not part of this ride");
            if (msg.sender == r.passenger) {
                fee = (r.fare * CANCELLATION_FEE_PERCENT) / 100;
            }
            refund = r.fare - fee;
        } else {
            revert("Ride cannot be cancelled at this stage");
        }

        r.status = RideStatus.Cancelled;          // effects before interactions
        _send(r.passenger, refund);
        _send(r.driver, fee);
        emit RideCancelled(rideId, msg.sender, refund, fee);
    }

    /// @notice Passenger disputes a completed journey instead of paying.
    function raiseDispute(uint256 rideId) external rideExists(rideId) onlyRidePassenger(rideId) {
        Ride storage r = rides[rideId];
        require(r.status == RideStatus.Completed, "Only completed rides can be disputed");
        r.status = RideStatus.Disputed;
        emit DisputeRaised(rideId, msg.sender);
    }

    /// @notice UrbanMove resolves a dispute by splitting the escrowed fare.
    /// @param driverPercent share of the fare (0-100) paid to the driver.
    function resolveDispute(uint256 rideId, uint256 driverPercent)
        external
        onlyAdmin
        nonReentrant
        rideExists(rideId)
    {
        Ride storage r = rides[rideId];
        require(r.status == RideStatus.Disputed, "Ride not disputed");
        require(driverPercent <= 100, "Percent must be 0-100");

        uint256 driverAmount = (r.fare * driverPercent) / 100;
        uint256 passengerRefund = r.fare - driverAmount;

        r.status = RideStatus.Resolved;
        if (driverAmount > 0) {
            drivers[r.driver].completedRides += 1;
        }
        _send(r.driver, driverAmount);
        _send(r.passenger, passengerRefund);
        emit DisputeResolved(rideId, driverAmount, passengerRefund);
    }

    // ------------------------------------------------------------------
    // Rating
    // ------------------------------------------------------------------
    /// @notice Passenger rates the driver (1-5 stars) once the ride is paid.
    function rateDriver(uint256 rideId, uint8 stars) external rideExists(rideId) onlyRidePassenger(rideId) {
        Ride storage r = rides[rideId];
        require(r.status == RideStatus.Paid, "Ride not paid");
        require(!r.rated, "Ride already rated");
        require(stars >= 1 && stars <= 5, "Stars must be 1-5");

        r.rated = true;
        drivers[r.driver].ratingTotal += stars;
        drivers[r.driver].ratingCount += 1;
        emit DriverRated(r.driver, rideId, stars);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------
    /// @notice Emergency stop for new bookings. Payments, refunds and disputes
    ///         still work so escrowed funds can never be locked.
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit PausedStateChanged(_paused);
    }

    // ------------------------------------------------------------------
    // Views and helpers
    // ------------------------------------------------------------------
    function getRide(uint256 rideId) external view rideExists(rideId) returns (Ride memory) {
        return rides[rideId];
    }

    /// @return rating average rating multiplied by 100 (e.g. 450 = 4.50 stars)
    function getDriverRating(address driver) external view returns (uint256 rating) {
        Driver storage d = drivers[driver];
        if (d.ratingCount == 0) return 0;
        return (d.ratingTotal * 100) / d.ratingCount;
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Helper to create a salted hash off-chain style (call, no transaction).
    ///         Only the hash is stored on-chain, never the raw location or licence.
    function hashData(string calldata data, uint256 salt) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(data, salt));
    }

    /// @notice Reject plain ETH transfers - fares must go through requestRide.
    receive() external payable {
        revert("Use requestRide to pay a fare");
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------
    function _releasePayment(uint256 rideId, bool claimedByDriver) private {
        Ride storage r = rides[rideId];
        uint256 platformFee = (r.fare * PLATFORM_FEE_PERCENT) / 100;
        uint256 driverAmount = r.fare - platformFee;

        r.status = RideStatus.Paid;                // effects before interactions
        drivers[r.driver].completedRides += 1;

        _send(r.driver, driverAmount);
        _send(admin, platformFee);
        emit PaymentReleased(rideId, r.driver, driverAmount, platformFee, claimedByDriver);
    }

    function _send(address payable to, uint256 amount) private {
        if (amount == 0 || to == address(0)) return;
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Transfer failed");
    }
}

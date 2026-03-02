// SPDX-License-Identifier: MIT
// ERC-ACP-Minimal: Minimal Agent Commerce Protocol — job escrow with evaluator attestation
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./IACPHook.sol";

/**
 * @title ACPMinimal
 * @dev Minimal Agent Commerce Protocol (ERC-ACP-Minimal): Open -> Funded -> Submitted -> Completed | Rejected | Expired. Only evaluator can complete.
 */
contract ACPMinimal is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        address hook; // optional hook contract (address(0) = no hook)
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        bool accepted; // true when provider has called acceptJob
    }

    IERC20 public paymentToken;
    uint256 public platformFeeBP; // 10000 = 100%
    address public platformTreasury;

    mapping(uint256 => Job) public jobs;
    uint256 public jobCounter;

    event JobCreated(uint256 indexed jobId, address indexed client, address indexed provider, address evaluator, uint256 expiredAt);
    event ProviderSet(uint256 indexed jobId, address indexed provider);
    event BudgetSet(uint256 indexed jobId, uint256 amount);
    event JobFunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobAccepted(uint256 indexed jobId, address indexed provider);
    event JobSubmitted(uint256 indexed jobId, address indexed provider);
    event JobCompleted(uint256 indexed jobId, address indexed evaluator, bytes32 reason);
    event JobRejected(uint256 indexed jobId, address indexed rejector, bytes32 reason);
    event JobExpired(uint256 indexed jobId);
    event PaymentReleased(uint256 indexed jobId, address indexed provider, uint256 amount);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);

    error InvalidJob();
    error WrongStatus();
    error Unauthorized();
    error ZeroAddress();
    error ExpiryTooShort();
    error ZeroBudget();
    error ProviderNotSet();
    error AlreadyAccepted();

    constructor(address paymentToken_, address treasury_) {
        if (paymentToken_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        paymentToken = IERC20(paymentToken_);
        platformTreasury = treasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    function setPlatformFee(uint256 feeBP_, address treasury_) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        if (feeBP_ > 10000) revert InvalidJob();
        platformFeeBP = feeBP_;
        platformTreasury = treasury_;
    }

    function _callHook(bytes memory call_, address hook_) internal {
        if (hook_ == address(0)) return;
        (bool ok, bytes memory ret) = hook_.call(call_);
        if (!ok) {
            if (ret.length > 0) {
                assembly { revert(add(ret, 32), mload(ret)) }
            }
            revert("Hook reverted");
        }
    }

    function createJob(address provider, address evaluator, uint256 expiredAt, string calldata description, address hook) external returns (uint256 jobId) {
        if (evaluator == address(0)) revert ZeroAddress();
        if (expiredAt <= block.timestamp + 5 minutes) revert ExpiryTooShort();
        jobId = ++jobCounter;
        jobs[jobId] = Job({
            id: jobId,
            client: msg.sender,
            provider: provider,
            evaluator: evaluator,
            hook: hook,
            description: description,
            budget: 0,
            expiredAt: expiredAt,
            status: JobStatus.Open,
            accepted: false
        });
        emit JobCreated(jobId, msg.sender, provider, evaluator, expiredAt);
        return jobId;
    }

    /// @dev Client sets provider when job was created with provider == address(0). Must be set before fund.
    ///      optParams is forwarded to the hook (e.g. auction proof / winning bid signature).
    function setProvider(uint256 jobId, address provider_, bytes calldata optParams) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider != address(0)) revert WrongStatus(); // already set
        if (provider_ == address(0)) revert ZeroAddress();
        _callHook(abi.encodeCall(IACPHook.preSetProvider, (jobId, provider_, optParams)), job.hook);
        job.provider = provider_;
        emit ProviderSet(jobId, provider_);
        _callHook(abi.encodeCall(IACPHook.postSetProvider, (jobId, provider_, optParams)), job.hook);
    }

    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        _callHook(abi.encodeCall(IACPHook.preSetBudget, (jobId, optParams)), job.hook);
        job.budget = amount;
        emit BudgetSet(jobId, amount);
        _callHook(abi.encodeCall(IACPHook.postSetBudget, (jobId, optParams)), job.hook);
    }

    function fund(uint256 jobId, bytes calldata optParams) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Open) revert WrongStatus();
        if (msg.sender != job.client) revert Unauthorized();
        if (job.provider == address(0)) revert ProviderNotSet();
        if (job.budget == 0) revert ZeroBudget();
        _callHook(abi.encodeCall(IACPHook.preFund, (jobId, optParams)), job.hook);
        job.status = JobStatus.Funded;
        paymentToken.safeTransferFrom(job.client, address(this), job.budget);
        emit JobFunded(jobId, job.client, job.budget);
        _callHook(abi.encodeCall(IACPHook.postFund, (jobId, optParams)), job.hook);
    }

    /// @dev Provider signals they have taken the job (flag only; no state change to lifecycle).
    function acceptJob(uint256 jobId) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        if (job.accepted) revert AlreadyAccepted();
        job.accepted = true;
        emit JobAccepted(jobId, msg.sender);
    }

    /// @dev Provider submits work, moving the job from Funded to Submitted for evaluator review.
    function submit(uint256 jobId) external {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Funded) revert WrongStatus();
        if (msg.sender != job.provider) revert Unauthorized();
        job.status = JobStatus.Submitted;
        emit JobSubmitted(jobId, msg.sender);
    }

    function complete(uint256 jobId, bytes32 reason) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Submitted) revert WrongStatus();
        if (msg.sender != job.evaluator) revert Unauthorized();
        _callHook(abi.encodeCall(IACPHook.preComplete, (jobId, reason)), job.hook);
        job.status = JobStatus.Completed;
        uint256 amount = job.budget;
        uint256 fee = (amount * platformFeeBP) / 10000;
        uint256 net = amount - fee;
        if (fee > 0) {
            paymentToken.safeTransfer(platformTreasury, fee);
        }
        if (net > 0) {
            paymentToken.safeTransfer(job.provider, net);
        }
        emit JobCompleted(jobId, msg.sender, reason);
        emit PaymentReleased(jobId, job.provider, net);
        _callHook(abi.encodeCall(IACPHook.postComplete, (jobId, reason)), job.hook);
    }

    /// @dev Client may reject only when Open; evaluator may reject when Funded or Submitted (refunds client).
    function reject(uint256 jobId, bytes32 reason) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status == JobStatus.Open) {
            if (msg.sender != job.client) revert Unauthorized();
        } else if (job.status == JobStatus.Funded || job.status == JobStatus.Submitted) {
            if (msg.sender != job.evaluator) revert Unauthorized();
        } else {
            revert WrongStatus();
        }
        _callHook(abi.encodeCall(IACPHook.preReject, (jobId, reason)), job.hook);
        JobStatus prev = job.status;
        job.status = JobStatus.Rejected;
        if ((prev == JobStatus.Funded || prev == JobStatus.Submitted) && job.budget > 0) {
            paymentToken.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }
        emit JobRejected(jobId, msg.sender, reason);
        _callHook(abi.encodeCall(IACPHook.postReject, (jobId, reason)), job.hook);
    }

    function claimRefund(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (job.id == 0) revert InvalidJob();
        if (job.status != JobStatus.Funded && job.status != JobStatus.Submitted) revert WrongStatus();
        if (block.timestamp < job.expiredAt) revert WrongStatus();
        job.status = JobStatus.Expired;
        if (job.budget > 0) {
            paymentToken.safeTransfer(job.client, job.budget);
            emit Refunded(jobId, job.client, job.budget);
        }
        emit JobExpired(jobId);
    }

    function getJob(uint256 jobId) external view returns (Job memory) {
        return jobs[jobId];
    }
}

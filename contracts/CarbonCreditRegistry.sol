// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title Carbon credit registry (reference implementation)
/// @author Rubbaite T. Hassain
/// @notice One token id per verified issuance batch (project + vintage). One token = one tonne CO2e.
///         Credits can be transferred until they are retired. Retirement burns them and records a
///         permanent, public retirement certificate, so the same tonne cannot be claimed twice.
/// @dev    Roles: DEFAULT_ADMIN_ROLE (governance, ideally a multisig/timelock), REGISTRAR_ROLE
///         (registers projects), VERIFIER_ROLE (independent verification bodies that issue batches),
///         PAUSER_ROLE (incident response).
contract CarbonCreditRegistry is ERC1155, AccessControl, Pausable {
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct Project {
        address developer;
        string methodology; // e.g. "VM0047 ARR"
        string metadataURI; // ipfs://... project design document
        bool active;
    }

    struct Batch {
        uint256 projectId;
        uint16 vintage; // year the reductions happened
        uint256 issued;
        uint256 retired;
        bytes32 verificationReportHash; // hash of the signed verification report (stored off-chain)
        address verifier;
    }

    struct Retirement {
        uint256 batchId;
        address retiredBy;
        uint256 amount;
        string beneficiary;
        string reason;
        uint64 timestamp;
    }

    uint256 public projectCount;
    uint256 public batchCount;
    mapping(uint256 => Project) public projects;
    mapping(uint256 => Batch) public batches;
    mapping(bytes32 => bool) public reportUsed;
    Retirement[] private _retirements;

    event ProjectRegistered(uint256 indexed projectId, address indexed developer, string methodology, string metadataURI);
    event ProjectStatusChanged(uint256 indexed projectId, bool active);
    event BatchIssued(uint256 indexed batchId, uint256 indexed projectId, uint16 vintage, uint256 amount, bytes32 reportHash, address indexed verifier);
    event CreditsRetired(uint256 indexed certificateId, uint256 indexed batchId, address indexed retiredBy, uint256 amount, string beneficiary, string reason);

    error UnknownProject(uint256 projectId);
    error ProjectInactive(uint256 projectId);
    error UnknownBatch(uint256 batchId);
    error ReportAlreadyUsed(bytes32 reportHash);
    error InvalidAmount();
    error InvalidVintage(uint16 vintage);
    error VerifierIsDeveloper();
    error EmptyBeneficiary();

    constructor(address admin, string memory uri_) ERC1155(uri_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    // ---------------------------------------------------------------- projects

    function registerProject(address developer, string calldata methodology, string calldata metadataURI)
        external
        onlyRole(REGISTRAR_ROLE)
        returns (uint256 projectId)
    {
        projectId = ++projectCount;
        projects[projectId] = Project(developer, methodology, metadataURI, true);
        emit ProjectRegistered(projectId, developer, methodology, metadataURI);
    }

    function setProjectActive(uint256 projectId, bool active) external onlyRole(REGISTRAR_ROLE) {
        if (projects[projectId].developer == address(0)) revert UnknownProject(projectId);
        projects[projectId].active = active;
        emit ProjectStatusChanged(projectId, active);
    }

    // ---------------------------------------------------------------- issuance

    /// @notice Issue credits for a verified monitoring period. Each verification report can be used once.
    function issueBatch(uint256 projectId, uint16 vintage, uint256 amount, bytes32 reportHash)
        external
        onlyRole(VERIFIER_ROLE)
        whenNotPaused
        returns (uint256 batchId)
    {
        Project storage p = projects[projectId];
        if (p.developer == address(0)) revert UnknownProject(projectId);
        if (!p.active) revert ProjectInactive(projectId);
        if (amount == 0) revert InvalidAmount();
        if (vintage < 2000 || vintage > _currentYear()) revert InvalidVintage(vintage);
        if (reportUsed[reportHash]) revert ReportAlreadyUsed(reportHash);
        // Segregation of duties: a verifier cannot certify its own project.
        if (msg.sender == p.developer) revert VerifierIsDeveloper();

        reportUsed[reportHash] = true;
        batchId = ++batchCount;
        batches[batchId] = Batch(projectId, vintage, amount, 0, reportHash, msg.sender);
        _mint(p.developer, batchId, amount, "");
        emit BatchIssued(batchId, projectId, vintage, amount, reportHash, msg.sender);
    }

    // ---------------------------------------------------------------- retirement

    /// @notice Permanently retire credits on behalf of a beneficiary. Retired credits are burned.
    function retire(uint256 batchId, uint256 amount, string calldata beneficiary, string calldata reason)
        external
        whenNotPaused
        returns (uint256 certificateId)
    {
        if (batches[batchId].projectId == 0) revert UnknownBatch(batchId);
        if (amount == 0) revert InvalidAmount();
        if (bytes(beneficiary).length == 0) revert EmptyBeneficiary();

        _burn(msg.sender, batchId, amount); // reverts on insufficient balance
        batches[batchId].retired += amount;

        certificateId = _retirements.length;
        _retirements.push(Retirement(batchId, msg.sender, amount, beneficiary, reason, uint64(block.timestamp)));
        emit CreditsRetired(certificateId, batchId, msg.sender, amount, beneficiary, reason);
    }

    function retirement(uint256 certificateId) external view returns (Retirement memory) {
        return _retirements[certificateId];
    }

    function retirementCount() external view returns (uint256) {
        return _retirements.length;
    }

    /// @notice Credits still in circulation for a batch (issued minus retired).
    function outstanding(uint256 batchId) external view returns (uint256) {
        Batch storage b = batches[batchId];
        return b.issued - b.retired;
    }

    // ---------------------------------------------------------------- admin

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setURI(string calldata newUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(newUri);
    }

    // ---------------------------------------------------------------- internals

    /// @dev Transfers are frozen while paused (incident response). Mint and burn paths check pause separately.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values) internal override {
        if (from != address(0) && to != address(0)) {
            _requireNotPaused();
        }
        super._update(from, to, ids, values);
    }

    function _currentYear() internal view returns (uint16) {
        // Good-enough calendar year from the timestamp (no leap-second precision needed for a vintage bound).
        return uint16(1970 + block.timestamp / 31_556_952);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

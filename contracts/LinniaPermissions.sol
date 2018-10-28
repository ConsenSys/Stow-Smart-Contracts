pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/lifecycle/Destructible.sol";
import "openzeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "openzeppelin-solidity/contracts/ownership/Ownable.sol";

import "./LinniaHub.sol";
import "./LinniaRecords.sol";
import "./LinniaUsers.sol";
import "./interfaces/PermissionPolicyI.sol";


contract LinniaPermissions is Ownable, Pausable, Destructible {
    struct Permission {
        bool canAccess;
        // IPFS hash of the encrypted key to decrypt the record
        string keyUri;
    }

    event LinniaAccessGranted(bytes32 indexed dataHash, address indexed owner,
        address indexed viewer, address sender
    );
    event LinniaAccessRevoked(bytes32 indexed dataHash, address indexed owner,
        address indexed viewer, address sender
    );
    event LinniaPermissionDelegateAdded(address indexed user, address indexed delegate);

    event LinniaPolicyChecked(
        bytes32 indexed dataHash,
        address indexed viewer,
        string keyUri,
        address indexed policy,
        bool isOk,
        address sender
    );

    LinniaHub public hub;
    // dataHash => viewer => permission mapping
    mapping(bytes32 => mapping(address => Permission)) public permissions;
    // user => delegate => bool mapping
    mapping(address => mapping(address => bool)) public delegates;

    /* Modifiers */
    modifier onlyUser() {
        require(hub.usersContract().isUser(msg.sender));
        _;
    }

    modifier onlyRecordOwnerOf(bytes32 dataHash, address owner) {
        require(hub.recordsContract().recordOwnerOf(dataHash) == owner);
        _;
    }

    modifier onlyWhenSenderIsDelegate(address owner) {
        require(delegates[owner][msg.sender]);
        _;
    }

    /* Constructor */
    constructor(LinniaHub _hub) public {
        hub = _hub;
    }

    /* Fallback function */
    function () public { }

    /* External functions */

    /// Check if a viewer has access to a record
    /// @param dataHash the hash of the unencrypted data
    /// @param viewer the address being allowed to view the data

    function checkAccess(bytes32 dataHash, address viewer)
        view
        external
        returns (bool)
    {
        return permissions[dataHash][viewer].canAccess;
    }

    /// Add a delegate for a user's permissions
    /// @param delegate the address of the delegate being added by user
    function addDelegate(address delegate)
        onlyUser
        whenNotPaused
        external
        returns (bool)
    {
        require(delegate != address(0));
        require(delegate != msg.sender);
        delegates[msg.sender][delegate] = true;
        emit LinniaPermissionDelegateAdded(msg.sender, delegate);
        return true;
    }

    /// Give a viewer access to a linnia record
    /// Called by owner of the record.
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user being granted permission to view the data
    /// @param keyUri IPFS hash of the encrypted key to decrypt the record
    function grantAccess(
        bytes32 dataHash, address viewer, string keyUri)
        onlyUser
        onlyRecordOwnerOf(dataHash, msg.sender)
        external
        returns (bool)
    {
        require(
            _grantAccess(dataHash, viewer, msg.sender, keyUri)
        );
        return true;
    }

    /// Give a viewer access to a linnia record
    /// Called by delegate to the owner of the record.
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user being permissioned to view the data
    /// @param owner the owner of the linnia record
    /// @param keyUri IPFS hash of the encrypted key to decrypt the record
    function grantAccessbyDelegate(
        bytes32 dataHash, address viewer, address owner, string keyUri)
        onlyWhenSenderIsDelegate(owner)
        onlyRecordOwnerOf(dataHash, owner)
        external
        returns (bool)
    {
        require(
            _grantAccess(dataHash, viewer, owner, keyUri)
        );
        return true;
    }

    /// Give a viewer access to a linnia record
    /// Called by owner of the record.
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user being granted permission to view the data
    /// @param keyUri IPFS hash of the encrypted key to decrypt the record
    function grantPolicyBasedAccess(
        bytes32 dataHash,
        address viewer,
        string keyUri,
        address[] policies)
        onlyUser
        onlyRecordOwnerOf(dataHash, msg.sender)
        external
        returns (bool)
    {
        require(dataHash != 0);

        // check policies and fail on first one that is not ok
        for (uint i = 0; i < policies.length; i++) {
            address curPolicy = policies[i];
            require(curPolicy != address(0));
            PermissionPolicyI currPolicy = PermissionPolicyI(curPolicy);
            bool isOk = currPolicy.checkPolicy(dataHash, viewer, keyUri);
            emit LinniaPolicyChecked(dataHash, viewer, keyUri, curPolicy, isOk, msg.sender);
            require(isOk);
        }

        require(_grantAccess(dataHash, viewer, msg.sender, keyUri));
        return true;
    }

    /// Revoke a viewer access to a linnia record
    /// Note that this does not necessarily remove the data from storage
    /// Called by owner of the record.
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user that has permission to view the data
    function revokeAccess(
        bytes32 dataHash, address viewer)
        onlyUser
        onlyRecordOwnerOf(dataHash, msg.sender)
        external
        returns (bool)
    {
        require(
            _revokeAccess(dataHash, viewer, msg.sender)
        );
        return true;
    }

    /// Revoke a viewer access to a linnia record
    /// Note that this does not necessarily remove the data from storage
    /// Called by delegate to the owner of the record.
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user that has permission to view the data
    /// @param owner the owner of the linnia record
    function revokeAccessbyDelegate(
        bytes32 dataHash, address viewer, address owner)
        onlyWhenSenderIsDelegate(owner)
        onlyRecordOwnerOf(dataHash, owner)
        external
        returns (bool)
    {
        require(_revokeAccess(dataHash, viewer, owner));
        return true;
    }

    /// Internal function to give a viewer access to a linnia record
    /// Called by external functions
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user being permissioned to view the data
    /// @param keyUri IPFS hash of the encrypted key to decrypt the record
    function _grantAccess(bytes32 dataHash, address viewer, address owner, string keyUri)
        whenNotPaused
        internal
        returns (bool)
    {
        // validate input
        require(owner != address(0));
        require(viewer != address(0));
        require(bytes(keyUri).length != 0);

        // TODO, Uncomment this to prevent grant access twice, It is commented for testing purposes
        // access must not have already been granted
        // require(!permissions[dataHash][viewer].canAccess);
        permissions[dataHash][viewer] = Permission({
            canAccess: true,
            keyUri: keyUri
            });
        emit LinniaAccessGranted(dataHash, owner, viewer, msg.sender);
        return true;
    }

    /// Internal function to revoke a viewer access to a linnia record
    /// Called by external functions
    /// Note that this does not necessarily remove the data from storage
    /// @param dataHash the data hash of the linnia record
    /// @param viewer the user that has permission to view the data
    /// @param owner the owner of the linnia record
    function _revokeAccess(bytes32 dataHash, address viewer, address owner)
        whenNotPaused
        internal
        returns (bool)
    {
        require(owner != address(0));
        // access must have already been grated
        require(permissions[dataHash][viewer].canAccess);
        permissions[dataHash][viewer] = Permission({
            canAccess: false,
            keyUri: ""
            });
        emit LinniaAccessRevoked(dataHash, owner, viewer, msg.sender);
        return true;
    }
}

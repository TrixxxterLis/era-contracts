// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @title IL2Messenger
 * @dev Interface for sending arbitrary length messages to L1
 */
interface IL2Messenger {
    function sendToL1(bytes memory _message) external returns (bytes32);
}

/**
 * @title IContractDeployer
 * @dev Interface for deploying contracts on L2
 */
interface IContractDeployer {
    struct ForceDeployment {
        bytes32 bytecodeHash;
        address newAddress;
        bool callConstructor;
        uint256 value;
        bytes input;
    }

    function forceDeployOnAddresses(ForceDeployment[] calldata _deployParams) external payable;

    function create2(bytes32 _salt, bytes32 _bytecodeHash, bytes calldata _input) external returns (address);
}

/**
 * @title IEthToken
 * @dev Interface for simulating ETH on L2
 */
interface IEthToken {
    function withdrawWithMessage(address _l1Receiver, bytes memory _additionalData) external payable;
}

/**
 * @title L2ContractHelper
 * @dev Helper library for working with L2 contracts on L1.
 */
library L2ContractHelper {
    bytes32 private constant CREATE2_PREFIX = keccak256("zksyncCreate2");

    function sendMessageToL1(IL2Messenger _messenger, bytes memory _message) internal returns (bytes32) {
        return _messenger.sendToL1(_message);
    }

    function computeCreate2Address(
        address _sender,
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes32 _constructorInputHash
    ) internal pure returns (address) {
        bytes32 senderBytes = bytes32(uint256(uint160(_sender)));
        bytes32 data = keccak256(
            abi.encodePacked(CREATE2_PREFIX, senderBytes, _salt, _bytecodeHash, _constructorInputHash)
        );

        return address(uint160(uint256(data)));
    }
}

contract MyImprovedContract {
    using L2ContractHelper for IL2Messenger;

    IL2Messenger public l2Messenger;

    constructor(IL2Messenger _l2Messenger) {
        l2Messenger = _l2Messenger;
    }

    function sendMessageToL1(bytes memory _message) external returns (bytes32) {
        return l2Messenger.sendMessageToL1(_message);
    }

    // Add more functions or logic as needed
}

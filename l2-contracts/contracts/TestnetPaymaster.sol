// ...

contract TestnetPaymaster is IPaymaster {
    modifier onlyBootloader() {
        require(msg.sender == BOOTLOADER_ADDRESS, "Only bootloader can call this contract");
        _;
    }

    function validateAndPayForPaymasterTransaction(
        bytes32,
        bytes32,
        Transaction calldata _transaction
    ) external payable onlyBootloader returns (bytes4 magic, bytes memory context) {
        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;

        require(_transaction.paymasterInput.length >= 4, "The standard paymaster input must be at least 4 bytes long");

        bytes4 paymasterInputSelector = bytes4(_transaction.paymasterInput[0:4]);
        if (paymasterInputSelector == IPaymasterFlow.approvalBased.selector) {
            // ...

            require(providedAllowance >= amount, "The user did not provide enough allowance");

            uint256 requiredETH = _transaction.gasLimit * _transaction.maxFeePerGas;
            if (amount < requiredETH) {
                // Allow transactions with insufficient funds for fee estimation
                magic = bytes4(0);
            }

            IERC20(token).transferFrom(userAddress, address(this), amount);

            (bool success, ) = payable(BOOTLOADER_ADDRESS).call{value: requiredETH}("");
            require(success, "Failed to transfer funds to the bootloader");
        } else {
            revert("Unsupported paymaster flow");
        }
    }

    // ...
}

}

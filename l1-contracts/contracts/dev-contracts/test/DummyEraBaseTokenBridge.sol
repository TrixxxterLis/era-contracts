// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

contract DummyEraBaseTokenBridge {
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address _prevMsgSender,
        address _l1Token,
        uint256 _amount
    ) external payable {}
}

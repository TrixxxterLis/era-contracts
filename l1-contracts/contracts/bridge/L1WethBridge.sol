// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IL1WethBridge, ConfirmL2TxStatus} from "./interfaces/IL1WethBridge.sol";
import {IL2WethBridge} from "./interfaces/IL2WethBridge.sol";
import {IL2Bridge} from "./interfaces/IL2Bridge.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {ConfirmL2TxStatus} from "./interfaces/IL1Bridge.sol";

import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {L2Message, TxStatus} from "../common/Messaging.sol";

import {UnsafeBytes} from "../common/libraries/UnsafeBytes.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";
import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR} from "../common/L2ContractAddresses.sol";
import {AddressAliasHelper} from "../vendor/AddressAliasHelper.sol";

import {ERA_CHAIN_ID, ETH_TOKEN_ADDRESS, ERA_WETH_ADDRESS, ERA_WETH_BRIDGE_ADDRESS, ERA_DIAMOND_PROXY, TWO_BRIDGES_MAGIC_VALUE} from "../common/Config.sol";
import {IBridgehub, L2TransactionRequestTwoBridgesInner, L2TransactionRequestDirect} from "../bridgehub/IBridgehub.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL1BridgeDeprecated} from "./interfaces/IL1BridgeDeprecated.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev This contract is designed to streamline and enhance the user experience
/// for bridging WETH tokens between L1 and L2 networks. The primary goal of this bridge is to
/// simplify the process by minimizing the number of transactions required, thus improving
/// efficiency and user experience.
/// @dev The default workflow for bridging WETH is performing three separate transactions: unwrap WETH to ETH,
/// deposit ETH to L2, and wrap ETH to WETH on L2. The `L1WethBridge` reduces this to a single
/// transaction, enabling users to bridge their WETH tokens directly between L1 and L2 networks.
/// @dev This contract accepts WETH deposits on L1, unwraps them to ETH, and sends the ETH to the L2
/// WETH bridge contract, where it is wrapped back into WETH and delivered to the L2 recipient.
/// @dev For withdrawals, the contract receives ETH from the L2 WETH bridge contract, wraps it into
/// WETH, and sends the WETH to the L1 recipient.
/// @dev The `L1WethBridge` contract works in conjunction with its L2 counterpart, `L2WethBridge`.
/// @dev Note VersionTracker stores at random addresses, so we can add it to the inheritance tree.
contract L1WethBridge is IL1WethBridge, ReentrancyGuard, Initializable, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @dev Event emitted when ETH is received by the contract.
    event EthReceived(uint256 amount);

    /// @dev The address of the WETH token on L1
    address payable public immutable override l1WethAddress;

    /// @dev bridgehub smart contract that is used to operate with L2 via asynchronous L2 <-> L1 communication
    IBridgehub public immutable override bridgehub;

    /// @dev we need to switch over from the diamondProxy Storage's isWithdrawalFinalized to this one for era
    /// we first deploy the new Mailbox facet, then transfer the Eth, then deploy this.
    /// this number is the first batch number that is settled on Era ST Diamond  before we update the Mailbox,
    /// as withdrawals from batches older than this might already be finalized
    uint256 internal eraIsWithdrawalFinalizedStorageSwitchBatchNumber;

    /// @dev A mapping chainId => bridgeProxy. Used to store the bridge proxy's address, and to see if it has been deployed yet.
    mapping(uint256 => address) public override l2BridgeAddress;

    /// @dev A mapping chainId => WethProxy. Used to store the weth proxy's address, and to see if it has been deployed yet.
    mapping(uint256 => address) public override l2WethAddress;

    /// @dev A mapping chainId =>  L2 deposit transaction hash =>  keccak256(account, amount)
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail
    /// @dev only used when it is not the base token, as then it is sent to refund recipient
    mapping(uint256 => mapping(bytes32 => bytes32)) public override depositHappened;

    /// @dev A mapping L2 chainId => Batch number => message number => flag
    /// @dev Used to indicate that L2 -> L1 WETH message was already processed
    mapping(uint256 chainId => mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized)))
        public isWithdrawalFinalizedShared;

    /// @dev A mapping chainId => amount. Used before we activate hyperbridging.
    mapping(uint256 => uint256) internal chainBalance;

    /// @dev have we enabled hyperbridging for chain yet
    mapping(uint256 => bool) internal hyperbridgingEnabled;

    /// @notice Emitted when the withdrawal is finalized on L1 and funds are released.
    /// @param to The address to which the funds were sent
    /// @param amount The amount of funds that were sent
    event EthWithdrawalFinalized(uint256 chainId, address indexed to, uint256 amount);

    /// @notice Checks that the message sender is the bridgehub or an Eth based Chain
    modifier onlyBridgehub() {
        require(msg.sender == address(bridgehub), "L1WETHBridge: not bridgehub");
        _;
    }

    /// @notice Checks that the message sender is the bridgehub or an Eth based Chain
    modifier onlyBridgehubOrEthChain(uint256 _chainId) {
        require(
            (msg.sender == address(bridgehub)) ||
                ((bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS) &&
                    msg.sender == bridgehub.getStateTransition(_chainId)),
            "L1WETHBridge: not bridgehub or eth chain"
        );
        _;
    }

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(address payable _l1WethAddress, IBridgehub _bridgehub) reentrancyGuardInitializer {
        l1WethAddress = _l1WethAddress;
        bridgehub = _bridgehub;
    }

    /// @dev Initializes a contract bridge for later use. Expected to be used in the proxy
    /// @dev During initialization deploys L2 WETH bridge counterpart as well as provides some factory deps for it
    /// @param _owner Address which can change L2 token implementation and upgrade the bridge
    /// implementation. The owner is the Governor and separate from the ProxyAdmin from now on, so that the Governor can call the bridge
    function initialize(
        address _owner,
        uint256 _eraIsWithdrawalFinalizedStorageSwitchBatchNumber
    ) external reentrancyGuardInitializer {
        _transferOwnership(_owner);
        require(_owner != address(0), "Governor address cannot be zero");

        eraIsWithdrawalFinalizedStorageSwitchBatchNumber = _eraIsWithdrawalFinalizedStorageSwitchBatchNumber;

        l2WethAddress[ERA_CHAIN_ID] = ERA_WETH_ADDRESS;
        l2BridgeAddress[ERA_CHAIN_ID] = ERA_WETH_BRIDGE_ADDRESS;

        // #if !EOA_GOVERNOR
        require(_owner.code.length > 0, "L1WETHBridge, owner cannot be EOA");
        // #endif
    }

    /// @dev used to specify special bridges not deployed by this contract
    /// these bridges can be custom bridges, so this is only allowed for the owner
    function initializeChainGovernance(
        uint256 _chainId,
        address _l2BridgeAddress,
        address _l2WethAddress
    ) external onlyOwner {
        l2BridgeAddress[_chainId] = _l2BridgeAddress;
        l2WethAddress[_chainId] = _l2WethAddress;
    }

    /// @notice Initiates a WETH deposit by depositing WETH into the L1 bridge contract, unwrapping it to ETH
    /// and sending it to the L2 bridge contract where ETH will be wrapped again to WETH and sent to the L2 recipient.
    /// only used for eth based chains.
    /// @param _l2Receiver The account address that should receive WETH on L2
    /// @param _l1Token The L1 token address which is deposited (needs to be WETH address)
    /// @param _mintValue The total amount of base tokens to be minted. Covers both gas and msg.Value.
    /// If the base token is ETH, this will be overriden with msg.value + amount
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses
    /// out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will
    /// be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be
    /// sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds
    /// are controllable through the Mailbox,
    /// since the Mailbox applies address aliasing to the from address for the L2 tx if the L1 msg.sender is a contract.
    /// Without address aliasing for L1 contracts as refund recipients they would not be able to make proper L2 tx
    /// requests
    /// through the Mailbox to use or withdraw the funds from L2, and the funds would be lost.
    /// @return txHash The L2 transaction hash of deposit finalization
    function deposit(
        uint256 _chainId,
        address _l2Receiver,
        address _l1Token,
        uint256 _mintValue,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) external payable nonReentrant returns (bytes32 txHash) {
        {
            require((_l1Token == l1WethAddress), "L1WETH Bridge: Invalid L1 token address");
            bool ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
            require(
                ethIsBaseToken,
                "L1WETH Bridge: Direct deposit via requestL2Transaction only available for Eth based chains"
            );
            require(l2BridgeAddress[_chainId] != address(0), "L1WETH Bridge: Bridge is not deployed");

            require(msg.value + _amount == _mintValue, "L1WETH Bridge: Incorrect amount of ETH sent");
            require(_amount > 0, "L1WETH Bridge: Amount is zero with direct deposit, call bridgehub directly instead");

            // Deposit WETH tokens from the depositor address to the smart contract address
            IERC20(l1WethAddress).safeTransferFrom(msg.sender, address(this), _amount);
            // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
            IWETH9(l1WethAddress).withdraw(_amount);
        }
        // we don't increase chainBalance since we do it in bridgehubDepositBaseToken
        {
            // Request the finalization of the deposit on the L2 side
            bytes memory l2TxCalldata = _getDepositL2Calldata(msg.sender, _l2Receiver, l1WethAddress, _amount);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            address refundRecipient = _refundRecipient;
            if (_refundRecipient == address(0)) {
                refundRecipient = msg.sender != tx.origin
                    ? AddressAliasHelper.applyL1ToL2Alias(msg.sender)
                    : msg.sender;
            }
            txHash = _depositSendTx(
                _chainId,
                _mintValue,
                _amount,
                l2TxCalldata,
                _l2TxGasLimit,
                _l2TxGasPerPubdataByte,
                refundRecipient
            );
        }
        emit DepositInitiatedSharedBridge(_chainId, txHash, msg.sender, _l2Receiver, _l1Token, _amount);
    }

    /// @dev internal to avoid stack too deep error
    function _depositSendTx(
        uint256 _chainId,
        uint256 _mintValue,
        uint256 _amount,
        bytes memory _l2TxCalldata,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) internal returns (bytes32 txHash) {
        // we don't save the depositAmount because base asset is sent to refundrecipient

        L2TransactionRequestDirect memory request = L2TransactionRequestDirect({
            chainId: _chainId,
            l2Contract: l2BridgeAddress[_chainId],
            mintValue: _mintValue,
            l2Value: _amount,
            l2Calldata: _l2TxCalldata,
            l2GasLimit: _l2TxGasLimit,
            l2GasPerPubdataByteLimit: _l2TxGasPerPubdataByte,
            l1GasPriceConverted: tx.gasprice,
            factoryDeps: new bytes[](0),
            refundRecipient: _refundRecipient
        });
        txHash = bridgehub.requestL2Transaction{value: _mintValue}(request);
    }

    /// @notice used by bridgehub to aquire mintValue. If l2Tx fails refunds are sent to refundrecipient on L2
    /// we also use it to keep to track each chain's assets
    function bridgehubDepositBaseToken(
        uint256 _chainId,
        address, //_prevMsgSender,
        address _token,
        uint256 _amount
    ) external payable override onlyBridgehubOrEthChain(_chainId) {
        require(_token == ETH_TOKEN_ADDRESS, "L1WETHBridge: Invalid token");
        require(msg.value == _amount, "L1WETHBridge: msg.value not equal to amount");
        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId] += _amount;
        }
    }

    /// @notice used by requestL2TransactionTwoBridges in Bridgehub
    /// specifies called chainId and caller, and requested transaction in _data.
    /// currently we only support a single tx, depositing.
    function bridgehubDeposit(
        uint256 _chainId,
        address _prevMsgSender,
        bytes calldata _data
    )
        external
        payable
        override
        nonReentrant
        onlyBridgehub
        returns (L2TransactionRequestTwoBridgesInner memory request)
    {
        (address _l1Token, uint256 _amount, address _l2Receiver) = abi.decode(_data, (address, uint256, address));
        {
            require(l2BridgeAddress[_chainId] != address(0), "L1WB: bridge not deployed");
            bool ethIsBaseToken = (bridgehub.baseToken(_chainId) == ETH_TOKEN_ADDRESS);
            require(!ethIsBaseToken, "L1WB: bridgehub deposit not allowed when eth is base token");
            require((_l1Token == l1WethAddress) || (_l1Token == ETH_TOKEN_ADDRESS), "L1WB: Invalid L1 token address");
        }
        if (_amount > 0) {
            // Deposit WETH tokens from the depositor address to the smart contract address
            IERC20(l1WethAddress).safeTransferFrom(_prevMsgSender, address(this), _amount);
            // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
            IWETH9(l1WethAddress).withdraw(_amount);
        }
        uint256 amount = _amount + msg.value;

        if (!hyperbridgingEnabled[_chainId]) {
            chainBalance[_chainId] += amount;
        }

        bytes32 txDataHash = keccak256(abi.encode(_prevMsgSender, amount));
        {
            // Request the finalization of the deposit on the L2 side
            bytes memory l2TxCalldata = _getDepositL2Calldata(_prevMsgSender, _l2Receiver, l1WethAddress, amount);

            // If the refund recipient is not specified, the refund will be sent to the sender of the transaction.
            // Otherwise, the refund will be sent to the specified address.
            // If the recipient is a contract on L1, the address alias will be applied.
            request = L2TransactionRequestTwoBridgesInner({
                magicValue: TWO_BRIDGES_MAGIC_VALUE,
                l2Contract: l2BridgeAddress[_chainId],
                l2Calldata: l2TxCalldata,
                factoryDeps: new bytes[](0),
                txDataHash: txDataHash
            });
        }

        emit BridgehubDepositInitiatedSharedBridge(_chainId, txDataHash, _prevMsgSender, _l2Receiver, _l1Token, amount);
    }

    /// @notice used by requestL2TransactionTwoBridges in Bridgehub
    /// used to confirm that the Mailbox has accepted a transaction.
    /// we can store the fact that the tx has happened using txDataHash and txHash
    function bridgehubConfirmL2Transaction(
        uint256 _chainId,
        bytes32 _txDataHash,
        bytes32 _txHash
    ) external override onlyBridgehub {
        require(depositHappened[_chainId][_txHash] == 0x00, "L1WETHBridge: tx already happened");
        depositHappened[_chainId][_txHash] = _txDataHash;
        emit BridgehubDepositFinalized(_chainId, _txDataHash, _txHash);
    }

    /// @dev Generate a calldata for calling the deposit finalization on the L2 WETH bridge contract
    function _getDepositL2Calldata(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount
    ) internal pure returns (bytes memory txCalldata) {
        txCalldata = abi.encodeCall(
            IL2Bridge.finalizeDeposit,
            (_l1Sender, _l2Receiver, _l1Token, _amount, new bytes(0))
        );
    }

    /// @notice Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// Note: Refund is performed by sending an equivalent amount of ETH on L2 to the specified deposit refund
    /// recipient address.
    function claimFailedDeposit(
        uint256 _chainId,
        address _depositSender,
        address _l1Token,
        uint256 _amount,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        bool proofValid = bridgehub.proveL1ToL2TransactionStatus(
            _chainId,
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof,
            TxStatus.Failure
        );
        require(proofValid, "L1WB: Invalid L2 transaction status proof");

        bytes32 txDataHash = depositHappened[_chainId][_l2TxHash];
        require(
            ((_amount > 0) && (txDataHash == keccak256(abi.encode(_depositSender, _amount)))),
            "L1WB: _amount is zero or deposit did not happen"
        );
        if (!hyperbridgingEnabled[_chainId]) {
            require(chainBalance[_chainId] >= _amount, "L1WB: chainBalance is too low");
            chainBalance[_chainId] -= _amount;
        }
        delete depositHappened[_chainId][_l2TxHash];

        // Withdraw funds
        // Wrap ETH to WETH tokens (smart contract address receives the equivalent _amount of WETH)
        IWETH9(l1WethAddress).deposit{value: _amount}();
        // Transfer WETH tokens from the smart contract address to the withdrawal receiver
        IERC20(l1WethAddress).safeTransfer(_depositSender, _amount);

        emit ClaimedFailedDepositSharedBridge(_chainId, _depositSender, _l1Token, _amount);
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BatchNumber The L2 batch number where the ETH (WETH) withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the ETH
    /// withdrawal message containing additional data about WETH withdrawal
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the ETH withdrawal log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(
            !isWithdrawalFinalizedShared[_chainId][_l2BatchNumber][_l2MessageIndex],
            "Withdrawal is already finalized"
        );

        if ((_chainId == ERA_CHAIN_ID) && ((_l2BatchNumber < eraIsWithdrawalFinalizedStorageSwitchBatchNumber))) {
            // in this case we have to check we don't double withdraw ether
            // we are not fully finalized if eth has not been withdrawn
            // note the WETH bridge has not yet been deployed, so it cannot be the case that we withdrew Eth but not WETH.
            bool alreadyFinalized = IGetters(ERA_DIAMOND_PROXY).isEthWithdrawalFinalized(
                _l2BatchNumber,
                _l2MessageIndex
            );
            require(!alreadyFinalized, "Withdrawal is already finalized");
        }

        (address l1WithdrawReceiver, uint256 amount, bool wrapToWeth) = _checkWithdrawal(
            _chainId,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _message,
            _merkleProof
        );
        if (!hyperbridgingEnabled[_chainId]) {
            require(chainBalance[_chainId] >= amount, "L1WB: chainBalance is too low");
            chainBalance[_chainId] -= amount;
        }
        isWithdrawalFinalizedShared[_chainId][_l2BatchNumber][_l2MessageIndex] = true;

        if (wrapToWeth) {
            // Wrap ETH to WETH tokens (smart contract address receives the equivalent amount of WETH)
            IWETH9(l1WethAddress).deposit{value: amount}();
            // Transfer WETH tokens from the smart contract address to the withdrawal receiver
            IERC20(l1WethAddress).safeTransfer(l1WithdrawReceiver, amount);

            emit WithdrawalFinalizedSharedBridge(_chainId, l1WithdrawReceiver, l1WethAddress, amount);
        } else {
            bool callSuccess;
            // Low-level assembly call, to avoid any memory copying (save gas)
            assembly {
                callSuccess := call(gas(), l1WithdrawReceiver, amount, 0, 0, 0, 0)
            }
            require(callSuccess, "L1WB: withdraw failed");
            emit EthWithdrawalFinalized(_chainId, l1WithdrawReceiver, amount);
        }
    }

    /// @dev check that the withdrawal is valid
    function _checkWithdrawal(
        uint256 _chainId,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) internal view returns (address l1Receiver, uint256 amount, bool wrapToWeth) {
        (l1Receiver, amount, wrapToWeth) = _parseL2WithdrawalMessage(_chainId, _message);

        L2Message memory l2ToL1Message;
        {
            bool thisIsBaseTokenBridge = bridgehub.baseTokenBridge(_chainId) == address(this);
            address l2Sender = thisIsBaseTokenBridge ? L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR : l2BridgeAddress[_chainId];

            // Check that the specified message was actually sent while withdrawing eth from L2.
            l2ToL1Message = L2Message({txNumberInBatch: _l2TxNumberInBatch, sender: l2Sender, data: _message});
        }

        {
            bool success = bridgehub.proveL2MessageInclusion(
                _chainId,
                _l2BatchNumber,
                _l2MessageIndex,
                l2ToL1Message,
                _merkleProof
            );
            require(success, "vq");
        }
    }

    /// @dev Decode the ETH withdraw message with additional data about WETH withdrawal that came from L2EthToken
    /// contract
    function _parseL2WithdrawalMessage(
        uint256 _chainId,
        bytes memory _message
    ) internal view returns (address l1Receiver, uint256 ethAmount, bool wrapToWeth) {
        // We check that the message is long enough to read the data.
        // Please note that there are two versions of the message:
        // 1. The message that is sent by `withdraw(address _l1Receiver)`
        // It should be equal to the length of the bytes4 function signature + address l1Receiver + uint256 amount = 4 + 20 + 32 = 56 (bytes).
        // 2. The message that is sent by `withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData)`
        // It should be equal to the length of the following:
        // bytes4 function signature + address l1Receiver + uint256 amount + address l2Sender + bytes _additionalData =
        // = 4 + 20 + 32 + 32 + _additionalData.length >= 68 (bytes).

        // So the data is expected to be at least 56 bytes long.
        require(_message.length >= 56, "Incorrect ETH message with additional data length");

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_message, 0);

        if (bytes4(functionSignature) == IMailbox.finalizeEthWithdrawal.selector) {
            (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            (ethAmount, offset) = UnsafeBytes.readUint256(_message, offset);
            wrapToWeth = false;

            if (l1Receiver == address(this)) {
                wrapToWeth = true;

                // Check that the message length is correct.
                // additionalData (WETH withdrawal data): l2 sender address + weth receiver address = 20 + 20 = 40 (bytes)
                // It should be equal to the length of the function signature + eth receiver address + uint256 amount +
                // additionalData = 4 + 20 + 32 + 40 = 96 (bytes).
                require(_message.length == 96, "Incorrect ETH message with additional data length 2");

                address l2Sender;
                (l2Sender, offset) = UnsafeBytes.readAddress(_message, offset);
                require(l2Sender == l2BridgeAddress[_chainId], "The withdrawal was not initiated by L2 bridge");

                // Parse additional data
                (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            }
        } else if (bytes4(functionSignature) == IL1BridgeDeprecated.finalizeWithdrawal.selector) {
            // note we use the IL1BridgeDeprecated only to send L1<>L2 messages,
            // and we use this interface so that when the switch happened the old messages could be processed

            // this message is a token withdrawal

            // Check that the message length is correct.
            // It should be equal to the length of the function signature + address + address + uint256 = 4 + 20 + 20 + 32 =
            // 76 (bytes).
            require(_message.length == 76, "Incorrect ETH withdrawal message length");
            (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
            address l1Token;
            (l1Token, offset) = UnsafeBytes.readAddress(_message, offset);
            (ethAmount, offset) = UnsafeBytes.readUint256(_message, offset);
        } else {
            revert("Incorrect message function selector");
        }
    }

    /// @dev The receive function is called when ETH is sent directly to the contract.
    receive() external payable {
        // Expected to receive ether in two cases:
        // 1. l1 WETH sends ether on `withdraw`
        require(msg.sender == l1WethAddress, "pn");
        emit EthReceived(msg.value);
    }
}

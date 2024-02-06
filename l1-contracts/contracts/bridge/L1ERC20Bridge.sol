// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IL1ERC20Bridge} from "./interfaces/IL1ERC20Bridge.sol";
import {IL1SharedBridge} from "./interfaces/IL1SharedBridge.sol";

import {IWETH9} from "./interfaces/IWETH9.sol";

import {L2ContractHelper} from "../common/libraries/L2ContractHelper.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Smart contract that allows depositing ERC20 tokens from Ethereum to hyperchains
/// @dev It is a legacy bridge from zkSync Era, that was deprecated in favour of shared bridge.
/// It is needed for backward compatibility with already integrated projects
contract L1ERC20Bridge is IL1ERC20Bridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Main shared bridge smart contract that is an upgrade of this contract.
    IL1SharedBridge public immutable override sharedBridge;

    /// @dev A mapping L2 batch number => message number => flag.
    /// @dev Used to indicate that L2 -> L1 message was already processed for zkSync Era withdrawals.
    /// @dev Please note, this mapping is used only for Era withdrawals, while `isWithdrawalFinalizedShared` is used for every other hyperchain in the shared Bridge
    mapping(uint256 l2BatchNumber => mapping(uint256 l2ToL1MessageNumber => bool isFinalized))
        public isWithdrawalFinalized;

    /// @dev A mapping account => L1 token address => L2 deposit transaction hash => amount.
    /// @dev Used for saving the number of deposited funds, to claim them in case the deposit transaction will fail in zkSync Era.
    /// @dev Please note, this mapping is used only for Era deposits, while `depositHappened` is used for every other hyperchain in the shared Bridge
    mapping(address account => mapping(address l1Token => mapping(bytes32 depositL2TxHash => uint256 amount)))
        public depositAmount;

    /// @dev The address that was used as a L2 bridge counterpart in zkSync Era.
    address public l2Bridge;

    /// @dev The address that is used as a beacon for L2 tokens in zkSync Era.
    address public l2TokenBeacon;

    /// @notice Stores the hash of the L2 token proxy contract's bytecode on Era
    bytes32 public l2TokenProxyBytecodeHash;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_lastWithdrawalLimitReset;

    /// @dev Deprecated storage variable related to withdrawal limitations.
    mapping(address => uint256) private __DEPRECATED_withdrawnAmountInWindow;

    /// @dev Deprecated storage variable related to deposit limitations.
    mapping(address => mapping(address => uint256)) private __DEPRECATED_totalDepositedAmountPerUser;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(IL1SharedBridge _sharedBridge) reentrancyGuardInitializer {
        sharedBridge = _sharedBridge;
    }

    /// @dev Initializes the reentrancy guard for new blockchain deployments.
    function initialize() external reentrancyGuardInitializer {}

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @return The L2 token address that would be minted for deposit of the given L1 token on zkSync Era.
    function l2TokenAddress(address _l1Token) public view returns (address) {
        bytes32 constructorInputHash = keccak256(abi.encode(address(l2TokenBeacon), ""));
        bytes32 salt = bytes32(uint256(uint160(_l1Token)));

        return L2ContractHelper.computeCreate2Address(l2Bridge, salt, l2TokenProxyBytecodeHash, constructorInputHash);
    }

    /*//////////////////////////////////////////////////////////////
                            ERA LEGACY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy deposit method with refunding the fee to the caller, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted.
    /// @dev If the token is bridged for the first time, the L2 token contract will be deployed. Note however, that the
    /// newly-deployed token does not support any custom logic, i.e. rebase tokens' functionality is not supported.
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// NOTE: the function doesn't use `nonreentrant` modifier, because the inner method does.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte
    ) external payable returns (bytes32 l2TxHash) {
       return deposit(_l2Receiver, _l1Token, _amount, _l2TxGasLimit, _l2TxGasPerPubdataByte, address(0));
    }

    /// @notice Legacy deposit method with no chainId, use another `deposit` method instead.
    /// @dev Initiates a deposit by locking funds on the contract and sending the request
    /// of processing an L2 transaction where tokens would be minted
    /// @param _l2Receiver The account address that should receive funds on L2
    /// @param _l1Token The L1 token address which is deposited
    /// @param _amount The total amount of tokens to be bridged
    /// @param _l2TxGasLimit The L2 gas limit to be used in the corresponding L2 transaction
    /// @param _l2TxGasPerPubdataByte The gasPerPubdataByteLimit to be used in the corresponding L2 transaction
    /// @return l2TxHash The L2 transaction hash of deposit finalization
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// NOTE: the function doesn't use `nonreentrant` modifier, because the inner method does.
    function deposit(
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        uint256 _l2TxGasLimit,
        uint256 _l2TxGasPerPubdataByte,
        address _refundRecipient
    ) public payable nonReentrant returns (bytes32 l2TxHash) {
        uint256 amount = _depositFundsToSharedBridge(msg.sender, IERC20(_l1Token), _amount);
        require(amount == _amount, "3T"); // The token has non-standard transfer logic

        uint256 mintValue = _l1Token == sharedBridge.l1WethAddress() ? msg.value + _amount : msg.value;

        l2TxHash = sharedBridge.depositLegacyErc20Bridge{value: msg.value}(
            msg.sender,
            _l2Receiver,
            _l1Token,
            mintValue,
            _amount,
            _l2TxGasLimit,
            _l2TxGasPerPubdataByte,
            _refundRecipient
        );
        depositAmount[msg.sender][_l1Token][l2TxHash] = _amount;
        emit DepositInitiated(l2TxHash, msg.sender, _l2Receiver, _l1Token, _amount);
    }

    /// @dev Transfers tokens from the depositor address to the smart contract address
    /// @return The difference between the contract balance before and after the transferring of funds
    function _depositFundsToSharedBridge(address _from, IERC20 _token, uint256 _amount) internal returns (uint256) {
        address l1WethAddress = sharedBridge.l1WethAddress();
        if (_token == l1WethAddress){
            uint256 balanceBefore = address(this).balance;
            // Unwrap WETH tokens (smart contract address receives the equivalent amount of ETH)
            IWETH9(l1WethAddress).withdraw(_amount);
            uint256 balanceAfter = address(this).balance;
            require(balanceAfter - balanceBefore == _amount, "EB: w eth w");
        } else {}
            uint256 balanceBefore = _token.balanceOf(address(sharedBridge));
            _token.safeTransferFrom(_from, address(sharedBridge), _amount);
            uint256 balanceAfter = _token.balanceOf(address(sharedBridge));

            return balanceAfter - balanceBefore;
        }
    }

    /// @notice Legacy method
    /// @dev Withdraw funds from the initiated deposit, that failed when finalizing on L2.
    /// @param _depositSender The address of the deposit initiator
    /// @param _l1Token The address of the deposited L1 ERC20 token
    /// @param _l2TxHash The L2 transaction hash of the failed deposit finalization
    /// @param _l2BatchNumber The L2 batch number where the deposit finalization was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction with deposit finalization
    function claimFailedDeposit(
        address _depositSender,
        address _l1Token,
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof
    ) external {
        uint256 amount = depositAmount[_depositSender][_l1Token][_l2TxHash];
        delete depositAmount[_depositSender][_l1Token][_l2TxHash];

        sharedBridge.claimFailedDepositLegacyErc20Bridge(
            _depositSender,
            _l1Token,
            amount,
            _l2TxHash,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _merkleProof
        );
        emit ClaimedFailedDeposit(_depositSender, _l1Token, amount);
    }

    /// @dev We should only call this
    function finalizeWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external {
        require(!isWithdrawalFinalized[_l2BatchNumber][_l2MessageIndex], "pw");
        // We don't need to set finalizeWithdrawal here, as we set it in the shared bridge

        (address l1Receiver, address l1Token, uint256 amount) = sharedBridge.finalizeWithdrawalLegacyErc20Bridge(
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _message,
            _merkleProof
        );
        emit WithdrawalFinalized(l1Receiver, l1Token, amount);
    }
}

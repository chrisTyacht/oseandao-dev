// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

// OSEAN DAO staking contract for OSEAN SKIPPER HOLDERS based on Thirdweb Staking20

// Token
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Meta transactions
import "@thirdweb-dev/contracts/external-deps/openzeppelin/metatx/ERC2771ContextUpgradeable.sol";

// Utils
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import { CurrencyTransferLib } from "@thirdweb-dev/contracts/lib/CurrencyTransferLib.sol";
import "@thirdweb-dev/contracts/eip/interface/IERC20Metadata.sol";

//  ==========  Features    ==========

import "@thirdweb-dev/contracts/extension/ContractMetadata.sol";
import "@thirdweb-dev/contracts/extension/PermissionsEnumerable.sol";
import { Staking20Upgradeable } from "./extensions/OseanStaking20Upgradeable.sol";
import "@thirdweb-dev/contracts/prebuilts/interface/staking/ITokenStake.sol";

contract OseanSkipperStake is
    Initializable,
    ContractMetadata,
    PermissionsEnumerable,
    ERC2771ContextUpgradeable,
    MulticallUpgradeable,
    Staking20Upgradeable,
    ITokenStake
{
    bytes32 private constant MODULE_TYPE = bytes32("TokenStake");
    uint256 private constant VERSION = 1;

    /// @dev ERC20 Reward Token address. See {_mintRewards} below.
    address public rewardToken;

    /// @dev Total amount of reward tokens in the contract.
    uint256 private rewardTokenBalance;
    
    constructor(
        address _nativeTokenWrapper,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _rewardToken,
        address _stakingToken,
        uint80 _timeUnit,
        uint256 _rewardRatioNumerator,
        uint256 _rewardRatioDenominator
    ) initializer Staking20Upgradeable(_nativeTokenWrapper) {
        // Set contract parameters directly in the constructor
        __ERC2771Context_init_unchained(_trustedForwarders);        

        require(_rewardToken != _stakingToken, "Reward Token and Staking Token can't be same.");
        rewardToken = _rewardToken;

        uint16 _stakingTokenDecimals = _stakingToken == CurrencyTransferLib.NATIVE_TOKEN
            ? 18
            : IERC20Metadata(_stakingToken).decimals();
        uint16 _rewardTokenDecimals = _rewardToken == CurrencyTransferLib.NATIVE_TOKEN
            ? 18
            : IERC20Metadata(_rewardToken).decimals();

        __Staking20_init(_stakingToken, _stakingTokenDecimals, _rewardTokenDecimals);
        _setStakingCondition(_timeUnit, _rewardRatioNumerator, _rewardRatioDenominator);

        _setupContractURI(_contractURI);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @dev Initializes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _rewardToken,
        address _stakingToken,
        uint80 _timeUnit,
        uint256 _rewardRatioNumerator,
        uint256 _rewardRatioDenominator
    ) external initializer {
        __ERC2771Context_init_unchained(_trustedForwarders);        

        require(_rewardToken != _stakingToken, "Reward Token and Staking Token can't be same.");
        rewardToken = _rewardToken;

        uint16 _stakingTokenDecimals = _stakingToken == CurrencyTransferLib.NATIVE_TOKEN
            ? 18
            : IERC20Metadata(_stakingToken).decimals();
        uint16 _rewardTokenDecimals = _rewardToken == CurrencyTransferLib.NATIVE_TOKEN
            ? 18
            : IERC20Metadata(_rewardToken).decimals();

        __Staking20_init(_stakingToken, _stakingTokenDecimals, _rewardTokenDecimals);
        _setStakingCondition(_timeUnit, _rewardRatioNumerator, _rewardRatioDenominator);

        _setupContractURI(_contractURI);
        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
    }

    /// @dev Returns the module type of the contract.
    function contractType() external pure virtual returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function contractVersion() external pure virtual returns (uint8) {
        return uint8(VERSION);
    }

    /// @dev Lets the contract receive ether to unwrap native tokens.
    receive() external payable {
        require(msg.sender == nativeTokenWrapper, "caller not native token wrapper.");
    }

    /// @dev Admin deposits reward tokens.
    function depositRewardTokens(uint256 _amount) external payable nonReentrant {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Not authorized");

        address _rewardToken = rewardToken == CurrencyTransferLib.NATIVE_TOKEN ? nativeTokenWrapper : rewardToken;

        uint256 balanceBefore = IERC20(_rewardToken).balanceOf(address(this));
        CurrencyTransferLib.transferCurrencyWithWrapper(
            rewardToken,
            _msgSender(),
            address(this),
            _amount,
            nativeTokenWrapper
        );
        uint256 actualAmount = IERC20(_rewardToken).balanceOf(address(this)) - balanceBefore;

        rewardTokenBalance += actualAmount;

        emit RewardTokensDepositedByAdmin(actualAmount);
    }

    /// @dev Admin can withdraw excess reward tokens.
    function withdrawRewardTokens(uint256 _amount) external nonReentrant {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()), "Not authorized");

        // to prevent locking of direct-transferred tokens
        rewardTokenBalance = _amount > rewardTokenBalance ? 0 : rewardTokenBalance - _amount;

        CurrencyTransferLib.transferCurrencyWithWrapper(
            rewardToken,
            address(this),
            _msgSender(),
            _amount,
            nativeTokenWrapper
        );

        // The withdrawal shouldn't reduce staking token balance. `>=` accounts for any accidental transfers.
        address _stakingToken = stakingToken == CurrencyTransferLib.NATIVE_TOKEN ? nativeTokenWrapper : stakingToken;
        require(
            IERC20(_stakingToken).balanceOf(address(this)) >= stakingTokenBalance,
            "Staking token balance reduced."
        );

        emit RewardTokensWithdrawnByAdmin(_amount);
    }

    /// @notice View total rewards available in the staking contract.
    function getRewardTokenBalance() external view override returns (uint256) {
        return rewardTokenBalance;
    }

    /*///////////////////////////////////////////////////////////////
                        Transfer Staking Rewards
    //////////////////////////////////////////////////////////////*/

    /// @dev Mint/Transfer ERC20 rewards to the staker.
    function _mintRewards(address _staker, uint256 _rewards) internal override {
        require(_rewards <= rewardTokenBalance, "Not enough reward tokens");
        rewardTokenBalance -= _rewards;
        CurrencyTransferLib.transferCurrencyWithWrapper(
            rewardToken,
            address(this),
            _staker,
            _rewards,
            nativeTokenWrapper
        );
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether staking related restrictions can be set in the given execution context.
    function _canSetStakeConditions() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /// @dev Checks whether contract metadata can be set in the given execution context.
    function _canSetContractURI() internal view override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }

    /*///////////////////////////////////////////////////////////////
                            Miscellaneous
    //////////////////////////////////////////////////////////////*/
    
    function _stakeMsgSender() internal view virtual override returns (address) {
        return _msgSender();
    }

    function _msgSender() internal view virtual override returns (address sender) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view virtual override returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }
}
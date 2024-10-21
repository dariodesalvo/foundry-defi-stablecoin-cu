//SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DSCEngine
 * @author Patrick Collins
 * 
 * The system is designed to be as minimal as possible, and have the tokens maintain 1
 * token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algoritmically Stable
 * 
 * It is similar to DAI had no governance, no fees, and was only backed by WETH and
 * WBTC.
 * 
 * Our DSC system should always be "overcollateralized". At no point, should the value of 
 * all collateral <= $ backed value of all the DSC.
 * 
 * @notice This contract is the core of the DSC System. It handles all the logic for mining
 * and redeeming DSC, as well as depositing & withdrawing collateral.
 * 
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {

    // Errors
    error DSCEngine__NeedsMoteThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowenToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__MintFailed();

    //Constants

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    // State Variables
    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) 
        private s_collateralDeposited;
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens; 

    // Events
    event CollateralDeposited(address indexed user,address indexed token,uint256 indexed amount);

    // Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount == 0){
            revert DSCEngine__NeedsMoteThanZero();
        }

        _;
    }

    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine_NotAllowenToken();
        }

        _;
    }

    // Functions

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressAndPriceFeedAddressesMustBeSameLength();
        }
        
        for (uint256 i=0; i<tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    // External Functions

    function depositCollateralAndMintDsc() external {}
    /*
     * @notice follows CEI   
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    ) 
        external 
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress) 
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral; 
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success){
            revert DSCEngine__TransferFailed();
        }
    }   

    function redeemCollateralForDsc() external {}
    
    // Threshold to let's say 150%
    // $100 ETH -> $74 ETH
    // $50 DSC

    function redeemCollateral() external {}
    /**
     * @notice follows CEI
     * @param amountDscToMint  The amount of descentralized stablecoin to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint)  external moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender); 
        bool minted = i_dsc.mint(msg.sender,amountDscToMint);
        if (!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}        

    function _getAccountInformation(address user) 
        private 
        view 
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    // Private & Internal View Functions
    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUSD) =  _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold / PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _getUSDValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    // Public & External View Functions

    function getUSDValue(
        address token,
        uint256 amount // in WEI
    )
        external
        view
        returns (uint256)
    {
        return _getUSDValue(token, amount);
    }


    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUSD){
        //loop through each collateral token, get the amount they deposited
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {

            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD +=  _getUSDValue(token, amount);      
        }

        return totalCollateralValueInUSD;
    }



}
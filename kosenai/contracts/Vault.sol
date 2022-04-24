pragma solidity ^0.5.12;

import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/GSN/Context.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20Detailed.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "../Interfaces/ICurveFi_DepositY.sol";
import "../Interfaces/ICurveFi_Gauge.sol";
import "../Interfaces/ICurveFi_Minter.sol";
import "../Interfaces/ICurveFi_SwapY.sol";
import "../Interfaces/IYERC20.sol";

contract Vault is Initializable, Context, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    address public curveFi_Deposit;
    address public curveFi_Swap;
    address public curveFi_LPToken;
    address public curveFi_LPGauge;
    address public curveFi_CRVMinter;
    address public curveFi_CRVToken;
    
    function initialize() external initializer {
        Ownable.initialize(_msgSender());
    }

    function setup(address _depositContract, address _gaugeContract, address _minterContract) external onlyOwner {
        require(_depositContract != address(0), "Incorrect deposit contract address");
        curveFi_Deposit = _depositContract;
        curveFi_Swap = ICurveFi_DepositY(curveFi_Deposit).curve();
        curveFi_LPGauge = _gaugeContract;
        curveFi_LPToken = ICurveFi_DepositY(curveFi_Deposit).token();
        require(ICurveFi_Gauge(curveFi_LPGauge).lp_token() == address(curveFi_LPToken), "Curve LP tokens does not match");        
        curveFi_CRVMinter = _minterContract;
        curveFi_CRVToken = ICurveFi_Gauge(curveFi_LPGauge).crv_token();
    }

    function deposit(uint256[1] memory _amounts) public {
        address stablecoins = ICurveFi_DepositY(curveFi_Deposit).underlying_coins(0);
        IERC20(stablecoins).safeTransferFrom(_msgSender(), address(this), _amounts[0]);
        IERC20(stablecoins).safeApprove(curveFi_Deposit, _amounts[0]);
        ICurveFi_DepositY(curveFi_Deposit).add_liquidity(_amounts, 0);
        uint256 curveLPBalance = IERC20(curveFi_LPToken).balanceOf(address(this));
        IERC20(curveFi_LPToken).safeApprove(curveFi_LPGauge, curveLPBalance);
        ICurveFi_Gauge(curveFi_LPGauge).deposit(curveLPBalance);
        crvTokenClaim();
        uint256 crvAmount = IERC20(curveFi_CRVToken).balanceOf(address(this));
        IERC20(curveFi_CRVToken).safeTransfer(_msgSender(), crvAmount);
    }

    function withdraw(uint256[1] memory _amounts) public {
        address stablecoins = ICurveFi_DepositY(curveFi_Deposit).underlying_coins(0);
        uint256 nWithdraw;
        uint256 i;
        nWithdraw = nWithdraw.add(normalize(stablecoins, _amounts[0]));
        uint256 withdrawShares = calculateShares(nWithdraw);
        uint256 notStaked = curveLPTokenUnstaked();
        if (notStaked > 0) {
            withdrawShares = withdrawShares.sub(notStaked);
        }
        ICurveFi_Gauge(curveFi_LPGauge).withdraw(withdrawShares);
        IERC20(curveFi_LPToken).safeApprove(curveFi_Deposit, withdrawShares);
        ICurveFi_DepositY(curveFi_Deposit).remove_liquidity_imbalance(_amounts, withdrawShares);
        IERC20 stablecoin = IERC20(stablecoins);
        uint256 balance = stablecoin.balanceOf(address(this));
        uint256 amount = (balance <= _amounts[0]) ? balance : _amounts[0];
        stablecoin.safeTransfer(_msgSender(), amount);
        
    }

    function curveLPTokenStaked() public view returns(uint256) {
        return ICurveFi_Gauge(curveFi_LPGauge).balanceOf(address(this));
    }
    
    function curveLPTokenUnstaked() public view returns(uint256) {
        return IERC20(curveFi_LPToken).balanceOf(address(this));
    }

    function curveLPTokenBalance() public view returns(uint256) {
        uint256 staked = curveLPTokenStaked();
        uint256 unstaked = curveLPTokenUnstaked();
        return unstaked.add(staked);
    }

    function crvTokenClaim() internal {
        ICurveFi_Minter(curveFi_CRVMinter).mint(curveFi_LPGauge);
    }

    function calculateShares(uint256 normalizedWithdraw) internal view returns(uint256) {
        uint256 nBalance = normalizedBalance();
        uint256 poolShares = curveLPTokenBalance();
        return poolShares.mul(normalizedWithdraw).div(nBalance);
    }

    function balanceOfAll() public view returns(uint256[1] memory balances) {
        address stablecoins = ICurveFi_DepositY(curveFi_Deposit).underlying_coins(0);
        uint256 curveLPBalance = curveLPTokenBalance();
        uint256 curveLPTokenSupply = IERC20(curveFi_LPToken).totalSupply();
        require(curveLPTokenSupply > 0, "No Curve LP tokens minted");
        uint256 yLPTokenBalance = ICurveFi_SwapY(curveFi_Swap).balances(int128(0));
        address yCoin = ICurveFi_SwapY(curveFi_Swap).coins(int128(0));
        uint256 yShares = yLPTokenBalance.mul(curveLPBalance).div(curveLPTokenSupply);
        uint256 yPrice = IYERC20(yCoin).getPricePerFullShare();
        balances[0] = yPrice.mul(yShares).div(1e18);
        
    }

    function normalizedBalance() public view returns(uint256) {
        address stablecoins = ICurveFi_DepositY(curveFi_Deposit).underlying_coins(0);
        uint256[1] memory balances = balanceOfAll();
        uint256 summ;
        summ = summ.add(normalize(stablecoins, balances[0]));
        return summ;
    }

    function normalize(address coin, uint256 amount) internal view returns(uint256) {
        uint8 decimals = ERC20Detailed(coin).decimals();
        if (decimals == 18) {
            return amount;
        } else if (decimals > 18) {
            return amount.div(uint256(10)**(decimals-18));
        } else if (decimals < 18) {
            return amount.mul(uint256(10)**(18 - decimals));
        }
    }
}
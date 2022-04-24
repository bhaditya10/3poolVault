const { BN } = require('@openzeppelin/test-helpers');
const { expect } = require('chai');
const ERC20 = artifacts.require('Stub_ERC20');
const YERC20 = artifacts.require('Stub_YERC20');
const CurveDeposit = artifacts.require('Stub_CurveFi_DepositY');
const CurveSwap = artifacts.require('Stub_CurveFi_SwapY');
const CurveLPToken = artifacts.require('Stub_CurveFi_LPTokenY');
const CurveCRVMinter = artifacts.require('Stub_CurveFi_Minter');
const CurveGauge = artifacts.require('Stub_CurveFi_Gauge');
const Vault = artifacts.require('Vault');

const supplies = {
    dai: new BN('1000000000000000000000000'),
    usdc: new BN('1000000000000'),
    tusd: new BN('1000000000000'),
    usdt: new BN('1000000000000000000000000')
};

const deposits = {
    dai: new BN('100000000000000000000'), 
    usdc: new BN('200000000'), 
    tusd: new BN('300000000'), 
    usdt: new BN('400000000000000000000')
}

contract('Vault for Curve.Fi', async([ owner, defiowner, user1, user2 ]) => {
    let dai;
    let ydai;
    let curveLPToken;
    let curveSwap;
    let curveDeposit;
    let crvToken;
    let curveMinter;
    let curveGauge;
    let vault;

    before(async() => {
        dai = await ERC20.new({ from: owner });
        await dai.methods['initialize(string,string,uint8,uint256)']('DAI', 'DAI', 18, supplies.dai, { from: owner });

        ydai = await YERC20.new({ from: owner });
        await ydai.initialize(dai.address, 'yDAI', 18, { from: owner });

        curveLPToken = await CurveLPToken.new({from:owner});
        await curveLPToken.methods['initialize()']({from:owner});

        curveSwap = await CurveSwap.new({ from: owner });
        await curveSwap.initialize(
            [ydai.address],
            [dai.address],
            curveLPToken.address, 10, { from: owner });
        await curveLPToken.addMinter(curveSwap.address, {from:owner});

        curveDeposit = await CurveDeposit.new({ from: owner });
        await curveDeposit.initialize(
            [ydai.address],
            [dai.address],
            curveSwap.address, curveLPToken.address, { from: owner });
        await curveLPToken.addMinter(curveDeposit.address, {from:owner});

        crvToken = await ERC20.new({ from: owner });
        await crvToken.methods['initialize(string,string,uint8,uint256)']('CRV', 'CRV', 18, 0, { from: owner });

        curveMinter = await CurveCRVMinter.new({ from: owner });
        await curveMinter.initialize(crvToken.address, { from: owner });
        await crvToken.addMinter(curveMinter.address, { from: owner });

        curveGauge = await CurveGauge.new({ from: owner });
        await curveGauge.initialize(curveLPToken.address, curveMinter.address, {from:owner});
        await crvToken.addMinter(curveGauge.address, { from: owner });

        vault = await Vault.new({from:defiowner});
        await vault.initialize({from:defiowner});
        await vault.setup(curveDeposit.address, curveGauge.address, curveMinter.address, {from:defiowner});

        await dai.transfer(user1, new BN('1000000000000000000000'), { from: owner });
      
        await dai.transfer(user2, new BN('1000000000000000000000'), { from: owner });

    });

    describe('Deposit DAI to Curve', () => {
        it('Deposit DAI', async() => {
            await dai.approve(vault.address, deposits.dai, {from:user1});

            let daiBefore = await dai.balanceOf(user1);

            await vault.deposit(
                [deposits.dai], {from:user1});

                
            let daiAfter = await dai.balanceOf(user1);

            expect(daiBefore.sub(daiAfter).toString(), "Not deposited DAI").to.equal(deposits.dai.toString());

        });

        it('DAI is wrapped with Y-tokens', async() => {
            expect((await dai.balanceOf(ydai.address)).toString(), "DAI not wrapped").to.equal(deposits.dai.toString());
        });

        it('deposited Y-tokens to Curve Swap', async() => {
            expect((await ydai.balanceOf(curveSwap.address)).toString(), "YDAI not deposited").to.equal(deposits.dai.toString());
        });

        it('LP-tokens of curve staked in Gauge', async() => {
            let lptokens = deposits.dai;
            expect((await vault.curveLPTokenStaked()).toString(), "Stake is absent").to.equal(lptokens.toString());
            expect((await curveGauge.balanceOf(vault.address)).toString(), "Stake is absent in Gauge").to.equal(lptokens.toString());
        });

        it('minted CRV tokens and transfered to the user', async() => {
            expect((await crvToken.balanceOf(user1)).toNumber(), "No CRV tokens").to.be.gt(0);
        });

    });
    describe('Additional deposit to create extra liquidity', () => {
        it('Additional deposit', async() => {
            await dai.approve(vault.address, deposits.dai, {from:user2});

            await vault.deposit(
                [deposits.dai], {from:user2});
        });
    });

    describe('Withdraw DAI from Curve', () => {
        it('Withdraw', async() => {
            let daiBefore = await dai.balanceOf(user1);
            await vault.withdraw(
                [deposits.dai],
                {from:user1});
                
            let daiAfter = await dai.balanceOf(user1);

            expect(daiAfter.sub(daiBefore).toString(), "Not withdrawn DAI").to.equal(deposits.dai.toString());

        });
    });
});

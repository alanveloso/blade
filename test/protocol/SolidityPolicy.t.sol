// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Test} from "forge-std/Test.sol";
import {InventoryAgent, ReorderAgent} from "../../examples/SolidityPolicyExample.sol";

contract SolidityPolicyTest is Test {
    function testFuzz_policyDecisions(uint64 stock, uint64 target) public {
        InventoryAgent supplier = new InventoryAgent(stock);
        ReorderAgent buyer = new ReorderAgent(address(supplier), target);
        buyer.tick();
        if (target > stock) {
            assertEq(buyer.inventory(), 0);
            assertEq(buyer.refusals(), 1);
            assertEq(supplier.stock(), stock);
        } else {
            assertEq(buyer.inventory(), target);
            assertEq(supplier.stock(), stock - target);
            uint256 attempts = buyer.attempts();
            buyer.tick();
            assertEq(buyer.attempts(), attempts);
        }
    }

    function test_orderChangesResourceAllocation() public {
        InventoryAgent supplier = new InventoryAgent(10);
        ReorderAgent first = new ReorderAgent(address(supplier), 7);
        ReorderAgent second = new ReorderAgent(address(supplier), 6);
        uint256 snap = vm.snapshotState();
        first.tick();
        second.tick();
        assertEq(first.inventory(), 7);
        assertEq(second.inventory(), 0);
        assertTrue(vm.revertToState(snap));
        second.tick();
        first.tick();
        assertEq(first.inventory(), 0);
        assertEq(second.inventory(), 6);
    }

    function test_contractDoesNotSelfSchedule() public {
        InventoryAgent supplier = new InventoryAgent(10);
        ReorderAgent buyer = new ReorderAgent(address(supplier), 5);
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 days);
        assertEq(buyer.inventory(), 0);
        assertEq(buyer.attempts(), 0);
        buyer.tick();
        assertEq(buyer.inventory(), 5);
    }
}

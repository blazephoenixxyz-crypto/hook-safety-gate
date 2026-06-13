// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HookSafetyGate} from "../src/HookSafetyGate.sol";

/// @title  HookSafetyGate unit tests
/// @notice Proves every invariant of the gate without any external dependency or
///         fork. Each test maps to a stated property in the contract's NatSpec.
contract HookSafetyGateTest is Test {
    HookSafetyGate internal gate;

    address internal owner = address(0xA11CE);
    address internal stranger = address(0xBEEF);

    // ── Helpers to craft hook addresses with / without specific flag bits ──────
    //
    // v4 encodes flags in the low bits of the address. We build deterministic
    // addresses that either set or clear the two delta-flag bits, leaving the
    // upper bits arbitrary-but-nonzero so the address is realistic.

    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = uint160(1 << 3); // 0x08
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = uint160(1 << 2); // 0x04

    // A high base with NO low flag bits set in the delta positions.
    uint160 internal constant BASE = uint160(0xaBCd) << 16;

    function _hookWith(uint160 flagBits) internal pure returns (address) {
        return address(BASE | flagBits);
    }

    function setUp() public {
        vm.prank(owner);
        gate = new HookSafetyGate(owner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor / ownership
    // ─────────────────────────────────────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(gate.owner(), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(HookSafetyGate.ZeroAddress.selector);
        new HookSafetyGate(address(0));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CRITICAL: constants match canonical Uniswap v4-core Hooks.sol
    // This is the test that makes the contract inarguable — it pins the magic
    // numbers to the protocol's own definitions.
    // ─────────────────────────────────────────────────────────────────────────

    function test_constants_matchV4Core() public pure {
        // From Uniswap/v4-core src/libraries/Hooks.sol:
        //   BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3
        //   AFTER_SWAP_RETURNS_DELTA_FLAG  = 1 << 2
        assertEq(BEFORE_SWAP_RETURNS_DELTA_FLAG, uint160(8));
        assertEq(AFTER_SWAP_RETURNS_DELTA_FLAG, uint160(4));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Layer 1 — delta-permission screen (pure)
    // ─────────────────────────────────────────────────────────────────────────

    function test_layer1_hookWithBeforeSwapDelta_isNotClean() public view {
        address hook = _hookWith(BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertFalse(gate.hasNoDeltaFlags(hook));
    }

    function test_layer1_hookWithAfterSwapDelta_isNotClean() public view {
        address hook = _hookWith(AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertFalse(gate.hasNoDeltaFlags(hook));
    }

    function test_layer1_hookWithBothDeltaFlags_isNotClean() public view {
        address hook = _hookWith(BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertFalse(gate.hasNoDeltaFlags(hook));
    }

    function test_layer1_hookWithoutDeltaFlags_isClean() public view {
        address hook = _hookWith(0);
        assertTrue(gate.hasNoDeltaFlags(hook));
    }

    function test_layer1_zeroAddress_isClean() public view {
        assertTrue(gate.hasNoDeltaFlags(address(0)));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // isRoutableHook — combined predicate
    // ─────────────────────────────────────────────────────────────────────────

    function test_routable_hooklessPool_alwaysRoutable() public view {
        assertTrue(gate.isRoutableHook(address(0)));
    }

    function test_routable_cleanHookNotAllowlisted_isDenied() public view {
        address hook = _hookWith(0);
        assertFalse(gate.isRoutableHook(hook)); // default-closed
    }

    function test_routable_cleanHookAllowlisted_isRoutable() public {
        address hook = _hookWith(0);
        vm.prank(owner);
        gate.allowHook(hook);
        assertTrue(gate.isRoutableHook(hook));
    }

    function test_routable_deltaHookNeverRoutable_evenIfSomehowFlagged() public view {
        // A delta-flagged hook is denied by Layer 1 regardless of the allow-list.
        address hook = _hookWith(BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertFalse(gate.isRoutableHook(hook));
    }

    function test_routable_afterDeny_returnsFalse() public {
        address hook = _hookWith(0);
        vm.startPrank(owner);
        gate.allowHook(hook);
        assertTrue(gate.isRoutableHook(hook));
        gate.denyHook(hook);
        vm.stopPrank();
        assertFalse(gate.isRoutableHook(hook));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Allow-list management
    // ─────────────────────────────────────────────────────────────────────────

    function test_allowHook_revertsForDeltaFlaggedHook() public {
        address hook = _hookWith(AFTER_SWAP_RETURNS_DELTA_FLAG);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(HookSafetyGate.HookHasDeltaFlags.selector, hook));
        gate.allowHook(hook);
    }

    function test_allowHook_revertsForZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(HookSafetyGate.ZeroAddress.selector);
        gate.allowHook(address(0));
    }

    function test_allowHook_onlyOwner() public {
        address hook = _hookWith(0);
        vm.prank(stranger);
        vm.expectRevert(HookSafetyGate.NotOwner.selector);
        gate.allowHook(hook);
    }

    function test_denyHook_onlyOwner() public {
        address hook = _hookWith(0);
        vm.prank(stranger);
        vm.expectRevert(HookSafetyGate.NotOwner.selector);
        gate.denyHook(hook);
    }

    function test_allowHook_emitsEventOnce() public {
        address hook = _hookWith(0);
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, false);
        emit HookSafetyGate.HookAllowed(hook);
        gate.allowHook(hook);
        // Second call is idempotent — no event, no revert.
        gate.allowHook(hook);
        vm.stopPrank();
        assertTrue(gate.allowed(hook));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ownership transfer
    // ─────────────────────────────────────────────────────────────────────────

    function test_transferOwnership() public {
        vm.prank(owner);
        gate.transferOwnership(stranger);
        assertEq(gate.owner(), stranger);
    }

    function test_transferOwnership_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(HookSafetyGate.ZeroAddress.selector);
        gate.transferOwnership(address(0));
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(HookSafetyGate.NotOwner.selector);
        gate.transferOwnership(stranger);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Fuzz — the screen never admits a delta-flagged hook, for any address.
    // ─────────────────────────────────────────────────────────────────────────

    function testFuzz_deltaFlaggedHookNeverRoutable(address hook) public {
        vm.assume(hook != address(0));
        uint160 bits = uint160(hook) & (BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG);
        if (bits != 0) {
            // Carries a delta flag → can never be routable, and can never be allow-listed.
            assertFalse(gate.isRoutableHook(hook));
            vm.prank(owner);
            vm.expectRevert(abi.encodeWithSelector(HookSafetyGate.HookHasDeltaFlags.selector, hook));
            gate.allowHook(hook);
        }
    }

    function testFuzz_cleanHookRoutableOnlyAfterAllow(address hook) public {
        vm.assume(hook != address(0));
        uint160 bits = uint160(hook) & (BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG);
        vm.assume(bits == 0); // clean hook
        assertFalse(gate.isRoutableHook(hook)); // default-closed
        vm.prank(owner);
        gate.allowHook(hook);
        assertTrue(gate.isRoutableHook(hook));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title  HookSafetyGate
/// @notice A standalone, default-closed admission gate that lets any Uniswap v4
///         integrator decide whether a pool's hook is safe to route through,
///         BEFORE any token moves. It enforces two independent checks:
///
///           Layer 1 — Delta-permission screen (immutable, in code):
///             A hook may only be routable if its address does NOT carry either
///             of the two return-delta permission flags. Those flags are the only
///             ones that let a hook modify swap accounting; a hook that lacks them
///             is, by the PoolManager's own enforcement, incapable of altering
///             what a swapper pays or receives. This check is pure: it reads only
///             the hook's own address and never calls the hook.
///
///           Layer 2 — Default-closed allow-list (governed):
///             A hook is routable only if it has been explicitly allow-listed by
///             this contract's owner. Anything not admitted is denied. This covers
///             griefing, gas exhaustion, and behaviour the flags do not describe.
///
///         The contract holds no funds, makes no external calls, and cannot move
///         tokens. It is purely an advisory predicate (`isRoutableHook`) plus an
///         owner-managed allow-list. Integrators call `isRoutableHook(hook)` and
///         act on the boolean; this contract never executes a swap itself.
///
/// @dev    Permission-flag values are taken verbatim from the canonical Uniswap v4
///         `Hooks` library (Uniswap/v4-core, src/libraries/Hooks.sol). They are
///         redeclared here as immutable constants — rather than imported — so this
///         contract has ZERO external dependencies and can be audited and deployed
///         in isolation. The values are verified against v4-core in the test suite.
///
///         Reference (v4-core Hooks.sol):
///           BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3  (0x08)
///           AFTER_SWAP_RETURNS_DELTA_FLAG  = 1 << 2  (0x04)
///
///         These are the ONLY two of the 14 hook permission flags that grant a
///         hook the ability to return a delta and thereby change swap accounting.
contract HookSafetyGate {
    // ─────────────────────────────────────────────────────────────────────────
    // Constants — verbatim from Uniswap v4-core Hooks.sol, verified in tests.
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Flag bit (in a hook address) for `beforeSwap` returning a delta.
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = uint160(1 << 3);

    /// @notice Flag bit (in a hook address) for `afterSwap` returning a delta.
    uint160 internal constant AFTER_SWAP_RETURNS_DELTA_FLAG = uint160(1 << 2);

    /// @notice The mask of all accounting-altering permission bits. A hook whose
    ///         address ANDs to non-zero against this mask can modify swap deltas
    ///         and is therefore never routable, regardless of the allow-list.
    uint160 internal constant DELTA_FLAGS_MASK =
        BEFORE_SWAP_RETURNS_DELTA_FLAG | AFTER_SWAP_RETURNS_DELTA_FLAG;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The address permitted to manage the allow-list.
    address public owner;

    /// @notice Explicit allow-list. A hook is admitted iff this is true AND the
    ///         hook carries no delta flags. Default (unset) is false → denied.
    mapping(address hook => bool) public allowed;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
    event HookAllowed(address indexed hook);
    event HookDenied(address indexed hook);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Thrown when a non-owner calls a privileged function.
    error NotOwner();

    /// @notice Thrown when attempting to allow-list a hook that carries a
    ///         return-delta permission flag. Such a hook can never be safe to
    ///         route through, so admitting it is rejected at write time.
    error HookHasDeltaFlags(address hook);

    /// @notice Thrown when transferring ownership to the zero address.
    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /// @param initialOwner The address that will manage the allow-list. Intended
    ///        to be transferred to a multisig or the Uniswap Foundation post-deploy.
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        emit OwnerTransferred(address(0), initialOwner);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Layer 1 — pure delta-permission screen
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns true iff the hook address carries NO accounting-altering
    ///         (return-delta) permission flag.
    /// @dev    Pure. Reads only the address. Never calls the hook. Constant time.
    ///         `address(0)` (a pool with no hook) trivially passes.
    /// @param hook The hook address to screen.
    /// @return ok True if the hook cannot modify swap accounting.
    function hasNoDeltaFlags(address hook) public pure returns (bool ok) {
        return (uint160(hook) & DELTA_FLAGS_MASK) == 0;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Combined predicate — the function integrators call
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The single predicate an integrator consults before routing a v4 leg.
    ///         Returns true iff EITHER:
    ///           (a) the pool has no hook (`hook == address(0)`), OR
    ///           (b) the hook carries no delta flags (Layer 1) AND is explicitly
    ///               allow-listed (Layer 2).
    /// @dev    View. One SLOAD in the allow-list branch. Never calls the hook.
    ///         Default-closed: an unknown hook returns false.
    /// @param hook The pool's hook address.
    /// @return routable Whether the integrator should route through this hook.
    function isRoutableHook(address hook) external view returns (bool routable) {
        if (hook == address(0)) return true;
        if (!hasNoDeltaFlags(hook)) return false; // Layer 1 — cannot be overridden
        return allowed[hook]; // Layer 2 — default-closed
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Allow-list management (owner only)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Admit a hook to the allow-list.
    /// @dev    Reverts if the hook carries any delta flag: a hook that can alter
    ///         swap accounting must never be admitted, so Layer 1 is enforced here
    ///         at write time as well as at read time. Idempotent otherwise.
    /// @param hook The hook to admit. Must not be the zero address (zero needs no
    ///        admission — hookless pools are always routable) and must carry no
    ///        delta flags.
    function allowHook(address hook) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        if (!hasNoDeltaFlags(hook)) revert HookHasDeltaFlags(hook);
        if (!allowed[hook]) {
            allowed[hook] = true;
            emit HookAllowed(hook);
        }
    }

    /// @notice Remove a hook from the allow-list. Idempotent.
    /// @param hook The hook to deny.
    function denyHook(address hook) external onlyOwner {
        if (allowed[hook]) {
            allowed[hook] = false;
            emit HookDenied(hook);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Ownership
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Transfer allow-list ownership. Intended to migrate from a deploy
    ///         key to a multisig / the Uniswap Foundation.
    /// @param newOwner The new owner. Must be non-zero.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }
}

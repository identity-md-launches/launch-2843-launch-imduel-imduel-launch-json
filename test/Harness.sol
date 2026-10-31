// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IChessEngine} from "../src/IChessEngine.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IMDuelHook} from "../src/IMDuelHook.sol";
import {Rules} from "../src/Rules.sol";

/// The hook's constructor arguments in order. All static, so abi.encode(config) equals the flat arguments.
struct HookConfig {
    IPoolManager manager;
    IChessEngine engine;
    Currency imd;
    uint256 minImd;
    uint256 minImduel;
    uint256 turnBlocks;
}

/// Test-only: sets up exact positions and applies a chosen move, to test mates, counts and how games end.
contract IMDuelHarness is IMDuelHook {
    using PoolIdLibrary for PoolKey;

    constructor(HookConfig memory c)
        IMDuelHook(c.manager, c.engine, c.imd, c.minImd, c.minImduel, c.turnBlocks)
    {}

    function setPosition(PoolId id, uint256 board, uint32 white, uint32 black, uint16 ply, uint16 quiet) external {
        Game storage g = games[id];
        (g.board, g.whiteState, g.blackState, g.ply, g.quiet) = (board, white, black, ply, quiet);
    }

    /// Plays `move` as if a turn owned by `owner`, whose trade paid `paid`, resolved to it: recorded, and a mate paid
    /// at once, inside an unlock as the next block's trade does.
    function applyMove(PoolKey calldata key, uint16 move, address owner, uint256 paid) external {
        manager.unlock(abi.encode(uint8(9), abi.encode(key, move, owner, paid)));
    }

    function unlockCallback(bytes calldata data) public override returns (bytes memory) {
        (uint8 action, bytes memory body) = abi.decode(data, (uint8, bytes));
        if (action != 9) return super.unlockCallback(data);
        _onlyManager();
        (PoolKey memory key, uint16 move, address owner, uint256 paid) = abi.decode(body, (PoolKey, uint16, address, uint256));
        this.applyAndPay(key, move, owner, paid);
        return "";
    }

    function applyAndPay(PoolKey calldata key, uint16 move, address owner, uint256 paid) external {
        require(msg.sender == address(this));
        PoolId id = key.toId();
        Game storage g = games[id];
        bool black = g.ply & 1 == 1;
        (uint32 mover, uint32 other) = black ? (g.blackState, g.whiteState) : (g.whiteState, g.blackState);
        Trade memory t = Trade(paid, owner, 9_000);
        uint256 team = teamOf(g.slice, g.gameNo, black);
        _apply(id, g, move, Rules.move(g.board, mover, other, black, move), t, team);
        if (g.moveResult == (black ? 2 : 1)) _payMate(id, key, g, t, team);
    }

    /// Sets what the current game's trading put into each pot (the mate's inflow cap), as if it had been traded.
    function setGameIn(PoolId id, uint256 in0, uint256 in1) external {
        gameIn[id] = (uint256(games[id].gameNo) << 224) | (in1 << 112) | in0;
    }

    /// `_add`, for the saturation tests.
    function add(uint256 w, uint256 shift, uint256 bits, uint256 by) external pure returns (uint256) {
        return _add(w, shift, bits, by);
    }

    /// The position key held for half-move `ply`.
    function history(PoolId id, uint256 ply) external view returns (uint64) {
        (uint256 lo, uint256 hi) = _lanes(id, ply);
        return _key(lo, hi, (ply % 16) >> 1);
    }
}

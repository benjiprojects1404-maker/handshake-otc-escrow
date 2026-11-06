// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
// TESTING ONLY. Odd tokens used to exercise Handshake's edge cases.

contract HsToken {
    string public name; string public symbol; uint8 public constant decimals = 18;
    uint public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    mapping(address => bool) public blocked;
    uint public feeBps;           // transfer tax, taken from the amount received
    bool public returnsNothing;   // USDT-style: no bool return
    event Transfer(address indexed from, address indexed to, uint value);
    event Approval(address indexed owner, address indexed spender, uint value);
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint a) external { totalSupply += a; balanceOf[to] += a; emit Transfer(address(0), to, a); }
    function setFee(uint b) external { feeBps = b; }
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function setReturnsNothing(bool b) external { returnsNothing = b; }
    function approve(address s, uint a) external returns (bool) { allowance[msg.sender][s] = a; emit Approval(msg.sender, s, a); return true; }
    function _move(address f, address t, uint a) internal {
        require(!blocked[f] && !blocked[t], "blocked");
        balanceOf[f] -= a;
        uint fee = a * feeBps / 10_000;
        balanceOf[t] += a - fee; totalSupply -= fee;
        emit Transfer(f, t, a - fee);
    }
    function transfer(address t, uint a) external returns (bool) {
        _move(msg.sender, t, a);
        if (returnsNothing) assembly { return(0, 0) }
        return true;
    }
    function transferFrom(address f, address t, uint a) external returns (bool) {
        uint al = allowance[f][msg.sender];
        if (al != type(uint).max) allowance[f][msg.sender] = al - a;
        _move(f, t, a);
        if (returnsNothing) assembly { return(0, 0) }
        return true;
    }
}

/// Re-enters the escrow from inside a token transfer.
contract HsReenterToken {
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;
    address public escrow; uint public targetId; uint8 public mode; // 1 = cancel, 2 = fillGivingToken
    function mint(address to, uint a) external { balanceOf[to] += a; }
    function arm(address e, uint id, uint8 m) external { escrow = e; targetId = id; mode = m; }
    function approve(address s, uint a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function _hook() internal {
        if (mode == 1) { mode = 0; (bool ok, bytes memory r) = escrow.call(abi.encodeWithSignature("cancelOffer(uint256)", targetId)); if (!ok) assembly { revert(add(r, 32), mload(r)) } }
        if (mode == 2) { mode = 0; (bool ok, bytes memory r) = escrow.call(abi.encodeWithSignature("fillOfferGivingToken(uint256)", targetId)); if (!ok) assembly { revert(add(r, 32), mload(r)) } }
    }
    function transfer(address t, uint a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[t] += a; _hook(); return true; }
    function transferFrom(address f, address t, uint a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; _hook(); return true;
    }
}

/// A wallet contract that refuses BDAG, then can be told to accept it.
contract HsRejecter {
    bool public accept;
    function setAccept(bool a) external { accept = a; }
    function exec(address to, uint value, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory r) = to.call{value: value}(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        return r;
    }
    receive() external payable { require(accept, "no BDAG"); }
}

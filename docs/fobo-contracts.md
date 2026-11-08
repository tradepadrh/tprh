# fobo.fun on Robinhood Chain (4663): contracts for Fobo Radar

Found in the public fobo.fun web app bundle on 2026-11-08 and checked on-chain (all have code).

| Contract | Address |
|---|---|
| FoboFactory | `0xd7e538e98A208fD19e46bc549FF4710C33664e18` |
| FoboHook (Uniswap v4 hook) | `0x0Af57F62982D03066ef917AcAd87F771c06528Ec` |
| FOBO token | `0x000DE658153f47f23e92973C8EB1e89762703676` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Universal Router | `0x204FAca1764B154221e35c0d20aBb3c525710498` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| V4 Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| FoboVesting | `0x51d217Ecf7c0e4EbF54258444B9617D012Fd7D0a` |
| FoboBurner | `0x5541141CC427441F7eD5BD93Bd16AC87a890990d` |
| Limit orders | `0x3126f62d604a0AA2de8788e3eC21dDd8F2a2f82a` |
| Keeper | `0x25C7aA4fFEBb3F34f220250538745FBf1978F367` |
| Revenue | `0x8819036A0f6940285b6ea6D6B80cdC702ce8CB54` |

## Events

- Factory `TokenLaunched(address indexed token, bytes32 indexed poolId, address indexed creator, address quote, int24 tickStart, uint256 devBuyTokens, string name, string ticker, string metadataURI)`
  topic `0x026e4b7423df355927284925c5926f282ed0c33e8de0f31ba7381738fb2f1ba2`
- Hook `FloorRaised(bytes32 indexed poolId, int24 tickF, uint160 sqrtPriceX96, uint256 quoteInFloor, uint256 circulating)`
  topic `0x278493127bed7f0a1a9fd94ed5331417484103ff48f77960c9ca96faa57eb1a9`
- Hook `TaxPaid(bytes32 indexed poolId, address indexed swapper, bool buy, uint256 quoteVolume, uint256 toFloor, uint256 toCreator, uint256 toTeam, uint256 toBurn)`
  topic `0x639358c9dfe96c6ea2ec519dc28116a00338fb17bf39881403037495072376ce`
- PoolManager `Swap(bytes32 indexed id, address indexed sender, int128 amount0, int128 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick, uint24 fee)`
  topic `0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f`
- Vesting `Locked(uint256 indexed id, address indexed token, address indexed beneficiary, address from, uint256 amount, uint64 start, uint32 duration)`
  topic `0xb887b9904f603fa70bf801ab6e7f779b25891174cf76ff194010b5a5a33f51c8`

## Views

- Hook `pools(bytes32 poolId)` selector `0xb5217bb4` returns 15 words:
  token, creator, launchedAt (unix), tickStart, tickF (floor tick), refTick, refBlock, lastRaiseBlock, snipePot, snipeReleased, merged, liqBand, pot, creatorOwed, reserve.
- Hook `floorOf(PoolKey)` returns (tickF, sqrtPriceX96, circulating).
- Hook `startOfBlockTick(bytes32 id)`.

## Notes

- About 9.4 blocks per second; ~91 launches in the last ~1.2M blocks (about 1.5 days) at the time of checking.
- Launch tax: first 60 s after `launchedAt`, falling from 90% to 2.5% (per Bitrue's write-up).
- Swap fee 2.5%: 1.5% floor, 0.6% creator, 0.4% protocol.
- Floor gap = price vs floor: compare current pool tick with `tickF`.

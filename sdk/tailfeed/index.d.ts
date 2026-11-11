/**
 * @typedef {Object} Feed
 * @property {bigint} feedId
 * @property {bigint} roundId
 * @property {bigint} answer       int256, 8 decimals
 * @property {number} startedAt    unix seconds
 * @property {number} updatedAt    unix seconds
 * @property {string} proxy        AggregatorV3-compatible proxy address
 */

/**
 * @typedef {Object} Round
 * @property {bigint} roundId
 * @property {bigint} answer
 * @property {number} startedAt
 * @property {number} updatedAt
 * @property {bigint} answeredInRound
 */

/**
 * @param {object} [opts]
 * @param {string} [opts.rpc]
 * @param {string} [opts.registry]
 * @returns {{ rpc: string, registry: string,
 *   getFeed: (feedId: number|bigint) => Promise<Feed>,
 *   readProxy: (proxy: string) => Promise<Round>,
 *   priceOf: (feed: Feed) => number,
 *   ageOf: (feed: Feed) => number }}
 */
export function createClient(opts) {}
export const TESTNET;

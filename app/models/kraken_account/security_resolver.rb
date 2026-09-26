# frozen_string_literal: true

# Resolves a Kraken asset to the security that represents it.
#
# One security per *asset*, never per trading pair. A position in BTC is one
# position whether it was bought with EUR, sold for USD or is sitting in an Earn
# wallet, so all of those must land on the same security or the holding is split
# across several, each looking a fraction of its real size.
#
# That rules out the generic resolver's provider search for this path: asked to
# resolve "CRYPTO:BTC" it answers with whatever pair its price provider ranks
# first -- BTCBRL, BTC-EUR, BTCUSD -- which is a different security each time the
# ranking moves, and never the one already in the database, because the ticker it
# returns is not the ticker that was asked for.
#
# The ticker is instead bound straight to the crypto price provider, exactly as
# Onchain::SecurityResolver does, and for the same reason. That also keeps one
# asset in one record across integrations: the CRYPTO: prefix is shared, so a
# coin held both on Kraken and on-chain is a single security rather than two.
class KrakenAccount::SecurityResolver
  TICKER_PREFIX = "CRYPTO:"

  # The only securities provider that prices bare crypto symbols.
  PRICE_PROVIDER = Onchain::SecurityResolver::PRICE_PROVIDER
  EXCHANGE_MIC = Onchain::SecurityResolver::EXCHANGE_MIC

  # Currencies the price provider can quote directly, so a price in one of them
  # needs no conversion.
  QUOTED_CURRENCIES = Provider::BinancePublic::QUOTE_TO_CURRENCY.values.uniq.freeze

  # Kraken suffixes a staked or bonded balance onto the asset code -- XBT.M,
  # ETH2.S, DOT28.S -- and those are the same asset in a different wallet. The
  # suffix can repeat: a balance payload reports bonded DOT as DOT28.S.S, so the
  # group is matched one-or-more times rather than once, or DOT28.S.S resolves to
  # a different security than the DOT28.S the ledger reports.
  STAKING_SUFFIX = /(?:\d*\.[A-Z]+)+\z/

  # Kraken's own legacy codes for the same asset: XBT and XXBT are BTC, XETH is
  # ETH, ZEUR is EUR. Shared with AssetNormalizer so a symbol canonicalised here
  # and one canonicalised there cannot disagree -- which is how BTC ended up
  # split across CRYPTO:BTC and CRYPTO:XBT.
  FIAT_PREFIXES = KrakenAccount::AssetNormalizer::FIAT_PREFIXES
  SYMBOL_FALLBACKS = KrakenAccount::AssetNormalizer::SYMBOL_FALLBACKS

  class << self
    def resolve(asset_symbol, currency: nil)
      asset = canonical_asset(asset_symbol)
      return nil if asset.blank?

      ticker = ticker_for(asset, currency)

      existing_security(ticker) || create_security(ticker, asset)
    end

    # A bare CRYPTO:<ASSET> ticker prices against USDT and is then converted,
    # which adds a round trip and the spread between two venues. Binance quotes
    # a handful of fiats directly, so when the account is denominated in one of
    # them the price is asked for in that currency and no conversion happens.
    def ticker_for(asset, currency)
      bare = "#{TICKER_PREFIX}#{asset}"
      quote = currency.to_s.upcase
      return bare if quote.blank? || quote == asset
      return bare unless QUOTED_CURRENCIES.include?(quote)

      quoted = "#{bare}#{quote}"
      quoted_pair_priceable?(quoted) ? quoted : bare
    end

    # The venue quotes the currency, but not necessarily for this asset: a small
    # coin may trade only against USDT. Asking for a pair that does not exist
    # leaves the security with no prices at all, which is worse than pricing in
    # USD and converting -- the holding silently values at zero.
    #
    # Memoised because resolve runs once per ledger entry, and a sync carries
    # thousands; the probe is one request per asset per process.
    def quoted_pair_priceable?(ticker)
      cache = (@quoted_pair_priceable ||= {})
      return cache[ticker] if cache.key?(ticker)

      cache[ticker] = probe_quoted_pair(ticker)
    end

    def probe_quoted_pair(ticker)
      provider = Security.provider_for(PRICE_PROVIDER)
      return false if provider.nil?

      response = provider.fetch_security_price(
        symbol: ticker, exchange_operating_mic: EXCHANGE_MIC, date: Date.current
      )
      response.success? && response.data.present?
    rescue StandardError => e
      # A transient failure downgrades this asset to the bare ticker for the
      # life of the process rather than leaving it unpriced; the next boot
      # retries.
      Rails.logger.info "KrakenAccount::SecurityResolver - #{ticker} not priceable (#{e.class}), using the bare ticker"
      false
    end

    # "XBT.M" -> "BTC", "DOT28.S" -> "DOT", "CRYPTO:ETH" -> "ETH"
    def canonical_asset(symbol)
      value = symbol.to_s.strip.upcase
      value = value.split(":", 2).last.to_s if value.include?(":")
      value = value.sub(STAKING_SUFFIX, "")
      value = FIAT_PREFIXES[value] || value
      SYMBOL_FALLBACKS[value] || value
    end

    private

      # Deliberately ignores exchange_operating_mic: a Security for this ticker
      # may already exist because another integration created it first, and
      # reusing it keeps one asset in one record. A blank price_provider would
      # fall back to whichever provider is enabled first, and only the crypto one
      # quotes a bare coin symbol, so it is filled in -- but a provider another
      # integration chose deliberately is left alone.
      def existing_security(ticker)
        security = Security.find_by(ticker: ticker)
        return nil if security.nil?

        security.update!(price_provider: PRICE_PROVIDER) if security.price_provider.blank?
        security.update!(offline: false) if security.offline?
        security
      end

      def create_security(ticker, asset)
        Security.create!(
          ticker: ticker,
          name: asset,
          exchange_operating_mic: EXCHANGE_MIC,
          price_provider: PRICE_PROVIDER
        )
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        Rails.logger.warn "KrakenAccount::SecurityResolver - could not create #{ticker}: #{e.message}"
        Security.find_by(ticker: ticker)
      end
  end
end

module knwtechs::coin {

    use std::signer;
    use aptos_framework::managed_coin;

    struct KNWCoin {}

    const KNW_COIN_SUPPLY: u64 = 1000000000; // 1000 * 10e6

    public fun init_module(sender: &signer) {
        managed_coin::initialize<KNWCoin>(
            sender,
            b"KNW Token",
            b"KNWT",
            6,
            true
        );
        managed_coin::register<KNWCoin>(sender);
        managed_coin::mint<KNWCoin>(sender, signer::address_of(sender), KNW_COIN_SUPPLY);
    }
}

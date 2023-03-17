module knwtechs::staking {

    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::account;
    use aptos_framework::coin::{Self};
    use aptos_framework::timestamp;
    use aptos_token::token::{Self, TokenId};
    use aptos_std::string::{String};
    use aptos_std::simple_map;
    use aptos_std::vector;
    use std::signer;
    use std::error;

    #[test_only]
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    #[test_only]
    use std::string;

    const ERESOURCE_DNE: u64 = 1;
    const E_NOT_STAKER: u64 = 2;
    const EOWNER_NOT_HAVING_ENOUGH_TOKEN: u64 = 3;
    const E_NOT_OWNER: u64 = 4;
    const E_INVALID_AMOUNT: u64 = 5;
    const E_ZERO_REWARDS: u64 = 6;
    const E_INSUFFICENT_BALANCE: u64 = 7;
    const E_NOT_ACTIVE: u64 = 8;
    const E_WRONG_COLLECTION: u64 = 9;
    const E_WRONG_CREATOR: u64 = 10;
    const E_ZERO_NFTS_STAKED: u64 = 11;

    struct Store<phantom CoinType> has key {
        stakers: simple_map::SimpleMap<address, Staker>,
        owners: simple_map::SimpleMap<TokenId, address>,
        nfts_staked: u64,
        rewards_per_hour: u64,
        active: bool,
        admin: address,
        collection_name: String,
        collection_creator: address,
        stake_events: EventHandle<StakeEvent>,
        unstake_events: EventHandle<UnstakeEvent>,
        claim_events: EventHandle<ClaimEvent>,
        signer_capability: account::SignerCapability,
    }

    struct Staker has store, copy {
        staked_tokens: vector<StakedNft>,
        amount_staked: u64,
        time_of_last_update: u64,
        unclaimed_rewards: u64
    }

    struct StakedNft has store, drop, copy {
        staker: address,
        token_id: TokenId
    }

    struct StakeEvent has drop, store {
        account: address,
        token_id: token::TokenId
    }

    struct UnstakeEvent has drop, store {
        account: address,
        token_id: token::TokenId
    }

    struct ClaimEvent has drop, store {
        account: address,
        amount: u64
    }

    public entry fun create_staking_contract<CoinType>(
        source: &signer,
        rewards_per_hour: u64,
        active: bool,
        collection_name: String,
        collection_creator: address,
        rewardsAmount: u64
    ) {
        
        assert!(coin::balance<CoinType>(signer::address_of(source)) >= rewardsAmount, error::invalid_argument(E_INSUFFICENT_BALANCE));
        let (resource_signer, resource_signer_cap) = account::create_resource_account(source, b"staking_contract_store");

        move_to(
            &resource_signer, Store<CoinType> {
                nfts_staked: 0,
                stakers: simple_map::create<address, Staker>(),
                owners: simple_map::create<TokenId, address>(),
                rewards_per_hour,
                active,
                admin: signer::address_of(source),
                collection_name,
                collection_creator,
                stake_events: account::new_event_handle<StakeEvent>(&resource_signer),
                unstake_events: account::new_event_handle<UnstakeEvent>(&resource_signer),
                claim_events: account::new_event_handle<ClaimEvent>(&resource_signer),
                signer_capability: resource_signer_cap,
            }
        );

        token::opt_in_direct_transfer(&resource_signer, true);
        coin::register<CoinType>(&resource_signer);
        coin::transfer<CoinType>(source, signer::address_of(&resource_signer), rewardsAmount);
    }

    public entry fun stake<CoinType>(
        account: &signer,
        store_addr: address,
        token_name: String,
        property_version: u64,
    ) acquires Store {
        
        assert!(exists<Store<CoinType>>(store_addr), error::invalid_argument(ERESOURCE_DNE));
        let store = borrow_global_mut<Store<CoinType>>(store_addr);
        assert!(store.active == true, error::internal(E_NOT_ACTIVE));

        let staker_address = signer::address_of(account);
        let token_id = token::create_token_id_raw(store.collection_creator, store.collection_name, token_name, property_version);
        assert!(token::balance_of(staker_address, token_id) >= 1, error::invalid_argument(EOWNER_NOT_HAVING_ENOUGH_TOKEN));
        let resource_signer = account::create_signer_with_capability(&store.signer_capability);
        if(simple_map::contains_key(&store.stakers, &staker_address)){
            let staker_info = simple_map::borrow_mut<address, Staker>(&mut store.stakers, &staker_address);
            let rewards = calculateRewards(
                staker_info.amount_staked, staker_info.time_of_last_update, store.rewards_per_hour);
            staker_info.unclaimed_rewards = staker_info.unclaimed_rewards + rewards;
        }else{
            simple_map::add<address, Staker>(&mut store.stakers, staker_address, Staker {
                staked_tokens: vector::empty<StakedNft>(),
                amount_staked: 0,
                time_of_last_update: timestamp::now_seconds(),
                unclaimed_rewards: 0
            });
        };
        token::transfer(account, token_id, signer::address_of(&resource_signer), 1);

        let staker_info = simple_map::borrow_mut<address, Staker>(&mut store.stakers, &staker_address);

        vector::push_back<StakedNft>(&mut staker_info.staked_tokens, StakedNft {
            staker: staker_address,
            token_id
        });

        staker_info.amount_staked = staker_info.amount_staked + 1;
        store.nfts_staked = store.nfts_staked + 1;

        simple_map::add(&mut store.owners, token_id, staker_address);
        staker_info.time_of_last_update = timestamp::now_seconds();

        event::emit_event(&mut store.stake_events, StakeEvent {
            account: signer::address_of(account),
            token_id,
        });
    }

    public entry fun unstake<CoinType>(
        account: &signer,
        store_addr: address,
        token_name: String,
        property_version: u64
    ) acquires Store {
        assert!(exists<Store<CoinType>>(store_addr), error::invalid_argument(ERESOURCE_DNE));

        let store = borrow_global_mut<Store<CoinType>>(store_addr);
        let account_address = signer::address_of(account);
        assert!(
            simple_map::contains_key<address, Staker>(&store.stakers, &account_address),
            error::invalid_argument(E_NOT_STAKER)
        );

        let staker_info = simple_map::borrow_mut<address, Staker>(&mut store.stakers, &account_address);
        assert!(staker_info.amount_staked > 0, error::invalid_argument(E_INVALID_AMOUNT));
        
        let token_id = token::create_token_id_raw(store.collection_creator, store.collection_name, token_name, property_version);
        assert!(
            *simple_map::borrow<TokenId, address>(&store.owners, &token_id) == account_address,
            error::invalid_argument(E_NOT_OWNER)
        );

        let rewards = calculateRewards(
                staker_info.amount_staked, staker_info.time_of_last_update, store.rewards_per_hour);

        staker_info.unclaimed_rewards = staker_info.unclaimed_rewards + rewards;

        let i=0;
        while(i < vector::length<StakedNft>(&staker_info.staked_tokens)){
            let staked_nft = vector::borrow<StakedNft>(&mut staker_info.staked_tokens, i);
            if(staked_nft.token_id == token_id){
                vector::remove(&mut staker_info.staked_tokens, i);
                staker_info.amount_staked = staker_info.amount_staked - 1;
                simple_map::remove<TokenId, address>(&mut store.owners, &token_id);
                let resource_signer = account::create_signer_with_capability(&store.signer_capability);
                token::opt_in_direct_transfer(&resource_signer, true);
                token::transfer(&resource_signer, token_id, account_address, 1);
                store.nfts_staked = store.nfts_staked - 1;
                staker_info.time_of_last_update = timestamp::now_seconds();
                event::emit_event(&mut store.unstake_events, UnstakeEvent {
                    account: signer::address_of(account),
                    token_id,
                });
                break
            };
            i = i+1;
        };
    }

    public entry fun claim<CoinType>(
        account: &signer,
        store_address: address
    ) acquires Store {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        let store = borrow_global_mut<Store<CoinType>>(store_address);
        let account_address = signer::address_of(account);

        assert!(
            simple_map::contains_key<address, Staker>(&store.stakers, &account_address),
            error::invalid_argument(E_NOT_STAKER)
        );
        assert!(
            simple_map::borrow<address, Staker>(&store.stakers, &account_address).amount_staked > 0,
            error::invalid_argument(E_INVALID_AMOUNT)
        );

        if(get_rewards_balance<CoinType>(store_address) > 0){
            let staker_info = simple_map::borrow_mut<address, Staker>(&mut store.stakers, &account_address);
            let rewards = calculateRewards(
                    staker_info.amount_staked, staker_info.time_of_last_update, store.rewards_per_hour);
            
            assert!(rewards > 0, error::invalid_argument(E_ZERO_REWARDS));

            staker_info.time_of_last_update = timestamp::now_seconds();
            staker_info.unclaimed_rewards = 0;

            let resource_signer = account::create_signer_with_capability(&store.signer_capability);
            if(!coin::is_account_registered<CoinType>(account_address)){
                coin::register<CoinType>(account);
            };
            coin::transfer<CoinType>(&resource_signer, account_address, rewards);
            event::emit_event(&mut store.claim_events, ClaimEvent {
                account: signer::address_of(account),
                amount: rewards,
            });
        };
    }

    // public entry fun update_staker_info<CoinType>(
    //     staker: address,
    //     store_address: address
    // ) acquires Store {
    //     assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
    //     let store = borrow_global_mut<Store<CoinType>>(store_address);
    //     assert!(
    //         simple_map::contains_key<address, Staker>(&store.stakers, &staker),
    //         error::invalid_argument(E_NOT_STAKER)
    //     );

    //     let staker_info = simple_map::borrow_mut<address, Staker>(&mut store.stakers, &staker);
    //     let rewards = calculateRewards(
    //             staker_info.amount_staked, staker_info.time_of_last_update, store.rewards_per_hour);
    //     staker_info.time_of_last_update = timestamp::now_seconds();
    //     if(rewards > 0){
    //         staker_info.unclaimed_rewards = staker_info.unclaimed_rewards + rewards;
    //     };
    // }

    /* Get CoinType coins holded by the resource account */
    public fun get_rewards_balance<CoinType>(
        store_address: address
    ): u64 {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        coin::balance<CoinType>(store_address)
    }

    /* Get the total amount of nfts staked */
    public fun get_amount_staked<CoinType>(
        store_address: address
    ): u64 acquires Store {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        borrow_global<Store<CoinType>>(store_address).nfts_staked
    }

    /* Deposit `amount` of CoinType coins in the staking resource account */
    public fun deposit_rewards_token<CoinType>(
        source: &signer,
        store_address: address,
        amount: u64
    ) acquires Store {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        let store = borrow_global_mut<Store<CoinType>>(store_address);
        let resource_signer = account::create_signer_with_capability(&store.signer_capability);
        coin::transfer<CoinType>(source, signer::address_of(&resource_signer), amount);
    }

    /* Get the amount of nfts staked by a given address */
    public fun get_nfts_staked_by_address<CoinType>(
        account: address,
        store_address: address
    ): u64 acquires Store {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        let store = borrow_global<Store<CoinType>>(store_address);
        
        assert!(simple_map::contains_key<address, Staker>(&store.stakers, &account), error::invalid_argument(E_NOT_STAKER));
        simple_map::borrow<address, Staker>(&store.stakers, &account).amount_staked
    }

    /* Get Staker struct for a given address */
    public fun get_staker_info<CoinType>(
        account: address,
        store_address: address
    ): Staker acquires Store {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        let store = borrow_global<Store<CoinType>>(store_address);

        assert!(simple_map::contains_key<address, Staker>(&store.stakers, &account), error::invalid_argument(E_NOT_STAKER));
        *simple_map::borrow<address, Staker>(&store.stakers, &account)
    }

    public fun get_rewards_for_staker<CoinType>(
        staker: address,
        store_address: address
    ): u64 acquires Store {
        assert!(exists<Store<CoinType>>(store_address), error::invalid_argument(ERESOURCE_DNE));
        let store = borrow_global<Store<CoinType>>(store_address);
        assert!(simple_map::contains_key<address, Staker>(&store.stakers, &staker), error::invalid_argument(E_NOT_STAKER));
        let staker_info = simple_map::borrow<address, Staker>(&store.stakers, &staker);
        calculateRewards(staker_info.amount_staked, staker_info.time_of_last_update, store.rewards_per_hour)
    }

    fun calculateRewards(
        amount_staked: u64,
        time_of_last_update: u64,
        rewardsPerHour: u64,
    ): u64 {
        let time_elapsed = timestamp::now_seconds() - time_of_last_update;    
        ((time_elapsed * amount_staked) * rewardsPerHour) / 3600
    }

    #[test_only]
    public fun create_collection_and_token(
        creator: &signer,
        collection_name: String,
        amount: u64,
        collection_max: u64,
        token_max: u64,
        property_keys: vector<String>,
        property_values: vector<vector<u8>>,
        property_types: vector<String>,
        collection_mutate_setting: vector<bool>,
        token_mutate_setting: vector<bool>,
    ): TokenId {

        token::create_collection(
            creator,
            collection_name,
            string::utf8(b"Collection: Hello, World"),
            string::utf8(b"https://aptos.dev"),
            collection_max,
            collection_mutate_setting
        );

        token::create_token_script(
            creator,
            collection_name,
            string::utf8(b"TestToken #1"),
            string::utf8(b"Hello, Token"),
            amount,
            token_max,
            string::utf8(b"https://aptos.dev"),
            signer::address_of(creator),
            100,
            0,
            token_mutate_setting,
            property_keys,
            property_values,
            property_types,
        );
        token::create_token_id_raw(signer::address_of(creator), collection_name, string::utf8(b"TestToken #1"), 0)
    }
    
    #[test_only]
    public fun init_account(user: address) {
        aptos_framework::aptos_account::create_account(user);
    }

    #[test_only]
    public fun create_and_mint_test_coin(sender: &signer, core_framework: signer, amount: u64) {
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&core_framework);
        coin::deposit(signer::address_of(sender), coin::mint(amount, &mint_cap));
        coin::destroy_mint_cap<AptosCoin>(mint_cap);
        coin::destroy_burn_cap<AptosCoin>(burn_cap);
        assert!(coin::balance<AptosCoin>(signer::address_of(sender)) == amount, 0);
    }

    #[test(admin = @0x1111, collection_creator = @0x2222, staker = @0x3333, core_framework = @aptos_framework)]
    public fun setup(admin: &signer, collection_creator: signer, staker: &signer, core_framework: signer): (address, TokenId) acquires Store {
        timestamp::set_time_has_started_for_testing(&core_framework);

        init_account(signer::address_of(admin));
        init_account(signer::address_of(&collection_creator));
        init_account(signer::address_of(staker));

        create_and_mint_test_coin(admin, core_framework, 5000000000);

        let collection_name = string::utf8(b"Test Collection");
        let rewards_amount = 4000000000; // 100
        let rewards_per_hour = 50000000; // 0.5 AptosCoin
        let token_test: TokenId = create_collection_and_token(
            &collection_creator,
            collection_name,
            1,
            5,
            1,
            vector<String>[],
            vector<vector<u8>>[],
            vector<String>[],
            vector<bool>[false,false,false],
            vector<bool>[false,false,false,false,false],
        );

        let (creator, _, token_name, token_version) = token::get_token_id_fields(&token_test);
        token::opt_in_direct_transfer(staker, true);
        token::transfer_with_opt_in(
            &collection_creator,
            creator,
            collection_name,
            token_name,
            token_version,
            signer::address_of(staker),
            1
        );

        let (creator, _, _, _) = token::get_token_id_fields(&token_test);
        create_staking_contract<AptosCoin>(
            admin,
            rewards_per_hour,
            true,
            collection_name,
            creator,
            rewards_amount
        );

        let store_address = account::create_resource_address(&signer::address_of(admin), b"staking_contract_store");

        assert!(exists<Store<AptosCoin>>(store_address), error::not_found(ERESOURCE_DNE));
        let store = borrow_global<Store<AptosCoin>>(store_address);
        assert!(store.active == true, error::internal(E_NOT_ACTIVE));
        assert!(store.collection_name == collection_name, error::internal(E_WRONG_COLLECTION));
        assert!(store.collection_creator == creator, error::internal(E_WRONG_CREATOR));
        assert!(store.rewards_per_hour == rewards_per_hour, error::internal(E_WRONG_CREATOR));
        assert!(get_rewards_balance<AptosCoin>(store_address) == rewards_amount, error::internal(E_ZERO_REWARDS));
        (store_address, token_test)
    }

    #[test(admin = @0x1111, collection_creator = @0x2222, staker = @0x3333, core_framework = @aptos_framework)]
    public entry fun stake_success(admin: &signer, collection_creator: signer, staker: signer, core_framework: signer) acquires Store {

        let staker_address = signer::address_of(&staker);
        let (store_address, token_id) = setup(admin, collection_creator, &staker, core_framework);
        let (_, _, token_name, token_version) = token::get_token_id_fields(&token_id);

        timestamp::update_global_time_for_test(11000000);

        assert!(token::balance_of(staker_address, token_id) == 1, error::internal(EOWNER_NOT_HAVING_ENOUGH_TOKEN));
        stake<AptosCoin>(&staker, store_address, token_name, token_version);
        assert!(token::balance_of(staker_address, token_id) == 0, 0);

        let store = borrow_global<Store<AptosCoin>>(store_address);

        assert!(store.nfts_staked == 1, error::internal(E_ZERO_NFTS_STAKED));
        assert!(simple_map::contains_key<address, Staker>(&store.stakers, &staker_address) == true, error::internal(E_NOT_STAKER));

        let staker = simple_map::borrow<address,Staker>(&store.stakers, &staker_address);

        assert!(staker.amount_staked == 1, error::internal(E_ZERO_NFTS_STAKED));
        assert!(vector::length(&staker.staked_tokens) == 1, error::internal(E_NOT_STAKER));

        let staked_token_id = vector::borrow(&staker.staked_tokens, 0).token_id;
        //let (staked_coll_creator, staked_coll_name, staked_token_name, staked_token_version) = token::get_token_id_fields(&staked_token_id);
        
        assert!(staked_token_id == token_id, 0);
        // assert!(staked_coll_creator == coll_creator, 0);
        // assert!(staked_coll_name == coll_name, 0);
        // assert!(staked_token_name == token_name, 0);
        // assert!(staked_token_version == token_version, 0);

        assert!(simple_map::contains_key<TokenId, address>(&store.owners, &staked_token_id), error::internal(E_NOT_OWNER));
        
    }

    #[test(admin = @0x1111, collection_creator = @0x2222, staker = @0x3333, core_framework = @aptos_framework)]
    public entry fun unstake_success(admin: &signer, collection_creator: signer, staker: signer, core_framework: signer) acquires Store {
        
        let staker_address = signer::address_of(&staker);
        let (store_address, token_id) = setup(admin, collection_creator, &staker, core_framework);
        let (_, _, token_name, token_version) = token::get_token_id_fields(&token_id);

        timestamp::update_global_time_for_test(11000000);

        assert!(token::balance_of(staker_address, token_id) == 1, error::internal(EOWNER_NOT_HAVING_ENOUGH_TOKEN));
        stake<AptosCoin>(&staker, store_address, token_name, token_version);
        assert!(token::balance_of(staker_address, token_id) == 0, 0);

        {
            let store = borrow_global<Store<AptosCoin>>(store_address);

            assert!(store.nfts_staked == 1, error::internal(E_ZERO_NFTS_STAKED));
            assert!(simple_map::contains_key<address, Staker>(&store.stakers, &staker_address) == true, error::internal(E_NOT_STAKER));

            let staker_info = simple_map::borrow<address,Staker>(&store.stakers, &staker_address);

            assert!(staker_info.amount_staked == 1, error::internal(E_ZERO_NFTS_STAKED));
            assert!(vector::length(&staker_info.staked_tokens) == 1, error::internal(E_NOT_STAKER));

            let staked_token_id = vector::borrow(&staker_info.staked_tokens, 0).token_id;
            
            assert!(staked_token_id == token_id, 0);
            assert!(simple_map::contains_key<TokenId, address>(&store.owners, &staked_token_id), error::internal(E_NOT_OWNER));
        };
        
        unstake<AptosCoin>(&staker, store_address, token_name, token_version);

        let store = borrow_global<Store<AptosCoin>>(store_address);
        assert!(token::balance_of(staker_address, token_id) == 1, error::internal(EOWNER_NOT_HAVING_ENOUGH_TOKEN));
        assert!(store.nfts_staked == 0, error::internal(E_INVALID_AMOUNT));
        assert!(simple_map::contains_key<address, Staker>(&store.stakers, &staker_address), error::internal(E_NOT_STAKER));
        let staker_info = simple_map::borrow<address, Staker>(&store.stakers, &staker_address);
        assert!(vector::length<StakedNft>(&staker_info.staked_tokens) == 0, 0);
        assert!(!simple_map::contains_key<TokenId, address>(&store.owners, &token_id), error::internal(E_NOT_STAKER));
    }

    #[test(admin = @0x1111, collection_creator = @0x2222, staker = @0x3333, core_framework = @aptos_framework)]
    public entry fun stake_claim_unstake_success(admin: &signer, collection_creator: signer, staker: signer, core_framework: signer) acquires Store {
        
        let staker_address = signer::address_of(&staker);
        let (store_address, token_id) = setup(admin, collection_creator, &staker, core_framework);
        let (_, _, token_name, token_version) = token::get_token_id_fields(&token_id);

        let time = 11000000;
        timestamp::update_global_time_for_test_secs(time);

        // Stake
        assert!(token::balance_of(staker_address, token_id) == 1, error::internal(EOWNER_NOT_HAVING_ENOUGH_TOKEN));
        stake<AptosCoin>(&staker, store_address, token_name, token_version);
        assert!(token::balance_of(staker_address, token_id) == 0, 0);
        {
            let store = borrow_global<Store<AptosCoin>>(store_address);

            assert!(store.nfts_staked == 1, error::internal(E_ZERO_NFTS_STAKED));
            assert!(simple_map::contains_key<address, Staker>(&store.stakers, &staker_address) == true, error::internal(E_NOT_STAKER));

            let staker_info = simple_map::borrow<address,Staker>(&store.stakers, &staker_address);

            assert!(staker_info.amount_staked == 1, error::internal(E_ZERO_NFTS_STAKED));
            assert!(vector::length(&staker_info.staked_tokens) == 1, error::internal(E_NOT_STAKER));

            let staked_token_id = vector::borrow(&staker_info.staked_tokens, 0).token_id;
            
            assert!(staked_token_id == token_id, 0);
            assert!(simple_map::contains_key<TokenId, address>(&store.owners, &staked_token_id), error::internal(E_NOT_OWNER));
        };

        // we let pass 24 hours, so we expect 12 CoinType as rewards
        let new_time = time + (3600*24);
        timestamp::update_global_time_for_test_secs(new_time);
        
        // Claim
        {
            let staker_rewards = get_rewards_for_staker<AptosCoin>(staker_address, store_address);
            assert!(staker_rewards > 0, error::internal(E_ZERO_REWARDS));
        };
        claim<AptosCoin>(&staker, store_address);
        {
            let store = borrow_global<Store<AptosCoin>>(store_address);
            let staker_info = simple_map::borrow<address,Staker>(&store.stakers, &staker_address);
            assert!(coin::balance<AptosCoin>(staker_address) > 0, error::internal(E_ZERO_REWARDS));
            assert!(staker_info.time_of_last_update == new_time, 0);
        };

        // Unstake
        unstake<AptosCoin>(&staker, store_address, token_name, token_version);
        {
            let store = borrow_global<Store<AptosCoin>>(store_address);
            let staker_info = simple_map::borrow<address,Staker>(&store.stakers, &staker_address);
            assert!(token::balance_of(staker_address, token_id) == 1, error::internal(EOWNER_NOT_HAVING_ENOUGH_TOKEN));
            assert!(store.nfts_staked == 0, error::internal(E_INVALID_AMOUNT));
            assert!(simple_map::contains_key<address, Staker>(&store.stakers, &staker_address), error::internal(E_NOT_STAKER));
            assert!(vector::length<StakedNft>(&staker_info.staked_tokens) == 0, 0);
            assert!(!simple_map::contains_key<TokenId, address>(&store.owners, &token_id), error::internal(E_NOT_STAKER));
        };
    }

    #[test(admin = @0x1111, collection_creator = @0x2222, staker = @0x3333, user = @0x4444, core_framework = @aptos_framework)]
    #[expected_failure(abort_code = 65539)]
    public entry fun cannot_stake_if_no_holder(admin: &signer, collection_creator: signer, staker: signer, user: signer, core_framework: signer) acquires Store {

        let (store_address, token_id) = setup(admin, collection_creator, &user, core_framework);
        let (_, _, token_name, token_version) = token::get_token_id_fields(&token_id);

        timestamp::update_global_time_for_test(11000000);

        stake<AptosCoin>(&staker, store_address, token_name, token_version);
    }

}
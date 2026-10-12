# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

########################################
# Dependencies
########################################
remove:
	rm -rf dependencies

install:
	forge soldeer install

update: remove install

########################################
# Format
########################################
fmt:
	forge fmt

########################################
# Build
########################################
clean:
	forge fmt && forge clean

build:
	forge build --sizes

clean-build: clean build

########################################
# Test
########################################
test-quick: build
	forge test --fuzz-runs 256

test-std: build
	forge test

test-gas: build
	forge test --gas-report

test-cov: build
	forge coverage --no-match-coverage "(script|test)"

test-fuzz: build
	forge test --fuzz-runs 10000

########################################
# LuciRoyaltyModel Deployments
########################################
deploy_LuciRoyaltyModel_testnet: build
	forge script --ledger --sender ${SENDER} --broadcast --sig "run(string,string,uint256)" script/Deploy.s.sol:Deploy "LuciRoyaltyModel.sol:LuciRoyaltyModel" sepolia 11155111
	sleep 60
	forge verify-contract $$(cat out.txt) src/LuciRoyaltyModel.sol:LuciRoyaltyModel --chain 11155111 --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

deploy_LuciRoyaltyModel_mainnet: build
	forge script --ledger --sender ${SENDER} --broadcast --sig "run(string,string,uint256)" script/Deploy.s.sol:Deploy "LuciRoyaltyModel.sol:LuciRoyaltyModel" mainnet 1
	sleep 60
	forge verify-contract $$(cat out.txt) src/LuciRoyaltyModel.sol:LuciRoyaltyModel --chain 1 --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

########################################
# LuciMarket Deployments
########################################
deploy_LuciMarket_testnet: build
	forge script --ledger --sender ${SENDER} --broadcast --sig "run(string,string,uint256)" script/Deploy.s.sol:Deploy "LuciMarket.sol:LuciMarket" sepolia 11155111
	sleep 60
	forge verify-contract $$(cat out.txt) src/LuciMarket.sol:LuciMarket --chain 11155111 --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

deploy_LuciMarket_mainnet: build
	forge script --ledger --sender ${SENDER} --broadcast --sig "run(string,string,uint256)" script/Deploy.s.sol:Deploy "LuciMarket.sol:LuciMarket" mainnet 1
	sleep 60
	forge verify-contract $$(cat out.txt) src/LuciMarket.sol:LuciMarket --chain 1 --watch --constructor-args ${CONSTRUCTOR_ARGS}
	@bash print_and_clean.sh

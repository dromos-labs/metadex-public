// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseSplitter, Splitter} from 'V3-test/unit/splitter/BaseSplitter.sol';
import {ISplitter} from 'V3/interfaces/splitter/ISplitter.sol';

contract UnitSplitterClaim is BaseSplitter {
  function test_WhenTheRecipientAlreadyClaimedItsBalance(
    uint256 _index,
    uint256 _globalIndex,
    uint256 _accounted
  ) external {
    // A live recipient already settled at the current index with nothing left, and no new inflow followed.
    address _recipient = _setupRecipients[bound(_index, 0, _RECIPIENT_COUNT - 1)];
    _setGlobalAccrualIndex(_globalIndex);
    _setAccountedBalance(_accounted);
    _setLastSettledIndex(_recipient, _globalIndex);

    // No new inflow: the live balance equals the already-accounted amount.
    _mockAndExpectTokenBalance(_token, address(_splitter), _accounted);

    // it should make no transfer (selector-only match, any args, so an unexpected payout fails loudly)
    vm.mockCallRevert(_token, abi.encodeWithSelector(IERC20.transfer.selector), bytes('unexpected transfer'));

    vm.recordLogs();
    uint256 _amount = _splitter.claim(_recipient);

    // it should leave the global accrual index unchanged
    assertEq(_splitter.globalAccrualIndex(), _globalIndex);
    // it should leave _recipient lastSettledIndex unchanged
    assertEq(_lastSettledIndexOf(_recipient), _globalIndex);
    // it should emit no event
    assertEq(vm.getRecordedLogs().length, 0);
    // it should return zero
    assertEq(_amount, 0);
  }

  function test_WhenTheRecipientOwesABalance(uint256 _index, uint256 _inflow) external {
    uint256 _bounded = bound(_index, 0, _RECIPIENT_COUNT - 1);
    address _recipient = _setupRecipients[_bounded];
    uint256 _share = _setupShares[_bounded];
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);
    _mockAndExpectTokenBalance(_token, address(_splitter), _inflow);

    uint256 _expectedIndex = (_inflow * _SCALE) / _MAX_PIPS;
    uint256 _expectedAmount = (_inflow * _share) / _MAX_PIPS;
    // it should transfer the amount to _recipient
    _mockAndExpectTokenTransfer(_token, _recipient, _expectedAmount);

    // it should emit Claimed with _recipient, _amount
    _expectEmit(address(_splitter));
    emit ISplitter.Claimed(_recipient, _expectedAmount);

    uint256 _amount = _splitter.claim(_recipient);

    (, uint256 _lastIndex, uint256 _balance) = _splitter.recipientState(_recipient);
    // it should accrue pending inflow into the global accrual index
    assertEq(_splitter.globalAccrualIndex(), _expectedIndex);
    // it should settle _recipient accrual into claimable
    assertEq(_lastIndex, _expectedIndex);
    // it should zero _recipient claimable
    assertEq(_balance, 0);
    // it should decrement the accounted balance by the amount
    assertEq(_splitter.accountedBalance(), _inflow - _expectedAmount);
    // it should return the amount
    assertEq(_amount, _expectedAmount);
  }

  function test_WhenTheRecipientWasRemovedWithLeftoverBalance(
    uint256 _index,
    uint256 _globalIndex,
    uint256 _locked,
    uint256 _laterInflow
  ) external {
    // Seed the post-removal state directly: the recipient's share is zero, but a balance was locked in at removal.
    address _recipient = _setupRecipients[bound(_index, 0, _RECIPIENT_COUNT - 1)];
    _locked = bound(_locked, 1, _MAX_INFLOW);
    _laterInflow = bound(_laterInflow, _MAX_PIPS, _MAX_INFLOW);
    // Leave headroom so folding the later inflow into the seeded index cannot overflow.
    _globalIndex = bound(_globalIndex, 0, type(uint256).max - (_laterInflow * _SCALE) / _MAX_PIPS);
    // The accounted balance always covers every settled-but-unclaimed balance, so it is at least the locked amount.
    uint256 _baseAccounted = _locked;

    _setGlobalAccrualIndex(_globalIndex);
    _setAccountedBalance(_baseAccounted);
    _setClaimable(_recipient, _locked);
    _setLastSettledIndex(_recipient, _globalIndex);
    _setSharePips(_recipient, 0);

    _mockAndExpectTokenBalance(_token, address(_splitter), _baseAccounted + _laterInflow);
    _mockAndExpectTokenTransfer(_token, _recipient, _locked);

    // it should emit Claimed with _recipient, _amount
    _expectEmit(address(_splitter));
    emit ISplitter.Claimed(_recipient, _locked);

    uint256 _amount = _splitter.claim(_recipient);

    (uint256 _sharePips,, uint256 _balance) = _splitter.recipientState(_recipient);
    // it should accrue no new share of later inflow
    assertEq(_sharePips, 0);
    // it should pay only the balance locked in before removal (asserted by _mockAndExpectTokenTransfer)
    // it should zero _recipient claimable
    assertEq(_balance, 0);
    // it should decrement the accounted balance by the locked balance
    assertEq(_splitter.accountedBalance(), _laterInflow);
    // it should return the locked balance
    assertEq(_amount, _locked);
  }

  function test_WhenTheAddressHasNeverBeenARecipient(address _recipient, uint256 _inflow) external {
    // Clearing the high bit guarantees the address is outside the high-bit-derived `setUp` list, so its share is zero.
    _recipient = address(uint160(_recipient) & ~_ADDRESS_HIGH_BIT);
    _assumeFuzzable(_recipient);
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);
    _mockAndExpectTokenBalance(_token, address(_splitter), _inflow);
    uint256 _expectedIndex = (_inflow * _SCALE) / _MAX_PIPS;

    // it should make no transfer (selector-only match, any args, so an unexpected payout fails loudly)
    vm.mockCallRevert(_token, abi.encodeWithSelector(IERC20.transfer.selector), bytes('unexpected transfer'));

    vm.recordLogs();
    uint256 _amount = _splitter.claim(_recipient);

    // it should accrue pending inflow into the global accrual index
    assertEq(_splitter.globalAccrualIndex(), _expectedIndex);
    // it should leave _recipient lastSettledIndex unchanged
    // A zero share accrues nothing, so `_settle` carries `lastSettledIndex` rather than advancing it.
    assertEq(_lastSettledIndexOf(_recipient), 0);
    // it should emit no event
    assertEq(vm.getRecordedLogs().length, 0);
    // it should return zero
    assertEq(_amount, 0);
  }

  function test_WhenTheSettledAccrualIsBelowOneWei(uint256 _index, uint256 _share) external {
    // A share in [MAX_PIPS / 2, MAX_PIPS) makes a single 1-wei inflow accrue a sub-wei fraction (it floors to zero),
    // while two of them together cross one whole wei — so we can observe the fraction being carried forward.
    address _recipient = _setupRecipients[bound(_index, 0, _RECIPIENT_COUNT - 1)];
    _share = bound(_share, _MAX_PIPS / 2, _MAX_PIPS - 1);
    _setSharePips(_recipient, _share);

    // First 1-wei inflow: the accrual floors below one wei.
    _mockAndExpectTokenBalance(_token, address(_splitter), 1);
    // it should make no transfer (selector-only match, any args, so an unexpected payout fails loudly)
    vm.mockCallRevert(_token, abi.encodeWithSelector(IERC20.transfer.selector), bytes('unexpected transfer'));
    assertEq(_splitter.claim(_recipient), 0);
    (, uint256 _lastIndex, uint256 _balance) = _splitter.recipientState(_recipient);
    // it should leave _recipient lastSettledIndex unchanged
    assertEq(_lastIndex, 0);
    assertEq(_balance, 0);

    // Second 1-wei inflow: the carried-forward fraction now reaches a whole wei. The specific transfer mock takes
    // precedence over the selector-only revert above for this exact payout.
    _mockAndExpectTokenBalance(_token, address(_splitter), 2);
    _mockAndExpectTokenTransfer(_token, _recipient, 1);
    // it should fold the accrual into the next settlement
    assertEq(_splitter.claim(_recipient), 1);
    (,, _balance) = _splitter.recipientState(_recipient);
    assertEq(_balance, 0);
  }

  function test_WhenTheInflowDividesEvenlyAcrossTheShares(uint256 _inflow) external {
    // An inflow that is a whole multiple of MAX_PIPS divides cleanly across every share, so each recipient gets its
    // exact slice with nothing stranded. The sender is irrelevant: a Splitter transfer and an arbitrary donation are
    // the same balance increase, so this also covers the donated-by-an-arbitrary-sender case.
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);
    _inflow -= _inflow % _MAX_PIPS;

    uint256 _running = _inflow;
    uint256 _distributed;
    for (uint256 _i; _i < _RECIPIENT_COUNT; ++_i) {
      uint256 _slice = (_inflow * _setupShares[_i]) / _MAX_PIPS;
      // The balance reflects every prior withdrawal, so only the first claim observes new inflow.
      _mockAndExpectTokenBalance(_token, address(_splitter), _running);
      _mockAndExpectTokenTransfer(_token, _setupRecipients[_i], _slice);

      // it should pay each recipient its exact slice
      assertEq(_splitter.claim(_setupRecipients[_i]), _slice);
      _running -= _slice;
      _distributed += _slice;
    }

    // it should distribute the full inflow leaving no dust
    assertEq(_distributed, _inflow);
    assertEq(_splitter.accountedBalance(), 0);
  }

  function test_WhenTheInflowDoesNotDivideEvenlyAcrossTheShares(uint256 _inflow) external {
    // A raw (non-MAX_PIPS-multiple) inflow forces the per-recipient floor in `_settle` across the whole list.
    // Bounding the inflow at MAX_PIPS keeps every slice >= 1 wei (matching the Minter's MIN_MINT_AMOUNT floor).
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);

    uint256 _running = _inflow;
    uint256 _distributed;
    for (uint256 _i; _i < _RECIPIENT_COUNT; ++_i) {
      // Direct pro-rata floor, independent of the contract's SCALE-based accumulator.
      uint256 _slice = (_inflow * _setupShares[_i]) / _MAX_PIPS;
      _mockAndExpectTokenBalance(_token, address(_splitter), _running);
      _mockAndExpectTokenTransfer(_token, _setupRecipients[_i], _slice);

      // it should pay each recipient its slice floored to whole wei
      assertEq(_splitter.claim(_setupRecipients[_i]), _slice);
      _running -= _slice;
      _distributed += _slice;
    }

    // it should strand less than one wei per recipient as dust
    uint256 _dust = _inflow - _distributed;
    assertLt(_dust, _RECIPIENT_COUNT);
    assertEq(_splitter.accountedBalance(), _dust);
  }

  function test_WhenClaimingAConcreteRepeatedSettlement() external {
    // A 1-pip recipient earns `inflow / MAX_PIPS` per settlement. Each 1_999_999 wei inflow accrues 1.999999 wei,
    // which floors to 1 and advances lastSettledIndex past the fraction — so, unlike the sub-wei case, the
    // remainder is stranded on every credited settlement instead of carried forward. All values are hand-derived;
    // globalAccrualIndex and lastSettledIndex move together, reaching after each settlement:
    //   first  settlement = 1_999_999 * 1e18 / 1_000_000 = 1_999_999e12
    //   second settlement = 3_999_998 * 1e18 / 1_000_000 = 3_999_998e12
    address _recipient = _setupRecipients[0];
    _setSharePips(_recipient, 1);
    uint256 _repeatedPaid;

    // First inflow: balance 1_999_999, accrual 1.999999 floors to 1.
    _mockAndExpectTokenBalance(_token, address(_splitter), 1_999_999);
    _mockAndExpectTokenTransfer(_token, _recipient, 1);
    // it should pay each credited settlement floored to whole wei
    _repeatedPaid += _splitter.claim(_recipient);
    assertEq(_repeatedPaid, 1);
    // it should advance the recipient lastSettledIndex past the stranded fraction
    assertEq(_lastSettledIndexOf(_recipient), 1_999_999e12);

    // The first claim left 1_999_998 wei behind; a second equal inflow brings the live balance to 3_999_997. The
    // accrual floors to 1 again and lastSettledIndex advances again, stranding another fraction.
    _mockAndExpectTokenBalance(_token, address(_splitter), 3_999_997);
    _mockAndExpectTokenTransfer(_token, _recipient, 1);
    _repeatedPaid += _splitter.claim(_recipient);
    assertEq(_repeatedPaid, 2);
    assertEq(_lastSettledIndexOf(_recipient), 3_999_998e12);

    // Settle the same 3_999_998 wei total in one shot on a fresh splitter. At one pip, the full accrual is
    // 3.999998 wei and floors once to 3, instead of flooring each credited settlement to 1.
    Splitter _oneShot = new Splitter(_token, _voter, _setupRecipients, _setupShares);
    vm.store(address(_oneShot), bytes32(_recipientStateSlot(_recipient)), bytes32(uint256(1)));
    _mockAndExpectTokenBalance(_token, address(_oneShot), 3_999_998);
    _mockAndExpectTokenTransfer(_token, _recipient, 3);
    uint256 _oneShotPaid = _oneShot.claim(_recipient);

    // it should pay more when the same total inflow is settled once
    assertEq(_oneShotPaid, 3);
    assertGt(_oneShotPaid, _repeatedPaid);
  }

  function test_WhenClaimingAConcreteOwedBalance() external {
    // A 25% recipient (250_000 pips) claiming a 4_000_000 wei inflow. Worked out by hand, not via the contract:
    //   globalAccrualIndex = 4_000_000 * 1e18 / 1_000_000 = 4e18
    //   payout      = 250_000 * 4e18 / 1e18         = 1_000_000  (exactly a quarter of the inflow)
    //   accounted   = 4_000_000 - 1_000_000          = 3_000_000
    address _recipient = _setupRecipients[0];
    _setSharePips(_recipient, 250_000);

    _mockAndExpectTokenBalance(_token, address(_splitter), 4_000_000);
    // it should pay the recipient its hardcoded slice
    _mockAndExpectTokenTransfer(_token, _recipient, 1_000_000);

    uint256 _paid = _splitter.claim(_recipient);

    (, uint256 _lastIndex, uint256 _balance) = _splitter.recipientState(_recipient);
    assertEq(_paid, 1_000_000);
    // it should accrue the inflow into the global accrual index
    assertEq(_splitter.globalAccrualIndex(), 4e18);
    // it should advance the recipient lastSettledIndex to the global accrual index
    assertEq(_lastIndex, 4e18);
    // it should zero the recipient claimable
    assertEq(_balance, 0);
    // it should decrement the accounted balance by the payout
    assertEq(_splitter.accountedBalance(), 3_000_000);
  }

  function test_WhenClaimingAConcreteUnevenSplit() external {
    // Three recipients splitting 333_333 / 333_333 / 333_334 pips, claiming a 1_000_001 wei inflow. By hand:
    //   floor(333_333 * 1_000_001 / 1_000_000) = 333_333  (recipients 0 and 1)
    //   floor(333_334 * 1_000_001 / 1_000_000) = 333_334  (recipient 2)
    //   paid out = 333_333 + 333_333 + 333_334 = 1_000_000, so 1 wei of the 1_000_001 inflow is stranded.
    address[] memory _recipients = new address[](3);
    _recipients[0] = makeAddr('unevenA');
    _recipients[1] = makeAddr('unevenB');
    _recipients[2] = makeAddr('unevenC');
    uint256[] memory _shares = new uint256[](3);
    _shares[0] = 333_333;
    _shares[1] = 333_333;
    _shares[2] = 333_334;
    Splitter _uneven = new Splitter(_token, _voter, _recipients, _shares);

    uint256[3] memory _expectedSlices = [uint256(333_333), 333_333, 333_334];
    // Only the first claim observes the inflow; later claims read the balance already drawn down by prior payouts.
    uint256[3] memory _balancesBeforeClaim = [uint256(1_000_001), 666_668, 333_335];

    for (uint256 _i; _i < 3; ++_i) {
      _mockAndExpectTokenBalance(_token, address(_uneven), _balancesBeforeClaim[_i]);
      _mockAndExpectTokenTransfer(_token, _recipients[_i], _expectedSlices[_i]);

      // it should pay each recipient its hardcoded floored slice
      assertEq(_uneven.claim(_recipients[_i]), _expectedSlices[_i]);
    }

    // it should strand exactly one wei of dust
    assertEq(_uneven.accountedBalance(), 1);
  }
}

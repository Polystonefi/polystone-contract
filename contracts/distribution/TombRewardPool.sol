// SPDX-License-Identifier: MIT

pragma solidity >=0.6.0 <0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../owner/Operator.sol";

// Note that this pool has no minter key of Poly (rewards).
// Instead, the governance will call Poly distributeReward method and send reward to this pool at the beginning.
contract PolyRewardPool is Operator {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Polys to distribute in the pool.
        uint256 lastRewardTime; // Last time that Polys distribution occurred.
        uint256 accPolyPerShare; // Accumulated Polys per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
    }

    IERC20 public Poly;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when Poly mining starts.
    uint256 public poolStartTime;

    uint256[] public epochTotalRewards = [80000 ether, 60000 ether];

    // Time when each epoch ends.
    uint256[3] public epochEndTimes;

    // Reward per second for each of 2 epochs (last item is equal to 0 - for sanity).
    uint256[3] public epochPolyPerSecond;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event RewardPaid(address indexed user, uint256 amount);

    constructor(address _Poly, uint256 _poolStartTime) public {
        require(block.timestamp < _poolStartTime, "late");
        if (_Poly != address(0)) Poly = IERC20(_Poly);

        poolStartTime = _poolStartTime;

        epochEndTimes[0] = poolStartTime + 4 days; // Day 2-5
        epochEndTimes[1] = epochEndTimes[0] + 5 days; // Day 6-10

        epochPolyPerSecond[0] = epochTotalRewards[0].div(4 days);
        epochPolyPerSecond[1] = epochTotalRewards[1].div(5 days);

        epochPolyPerSecond[2] = 0;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(
                poolInfo[pid].token != _token,
                "PolyRewardPool: existing pool?"
            );
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime
    ) public onlyOperator {
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted = (_lastRewardTime <= poolStartTime) ||
            (_lastRewardTime <= block.timestamp);
        poolInfo.push(
            PoolInfo({
                token: _token,
                allocPoint: _allocPoint,
                lastRewardTime: _lastRewardTime,
                accPolyPerShare: 0,
                isStarted: _isStarted
            })
        );
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's Poly allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Return accumulate rewards over the given _fromTime to _toTime.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime)
        public
        view
        returns (uint256)
    {
        for (uint8 epochId = 2; epochId >= 1; --epochId) {
            if (_toTime >= epochEndTimes[epochId - 1]) {
                if (_fromTime >= epochEndTimes[epochId - 1]) {
                    return
                        _toTime.sub(_fromTime).mul(epochPolyPerSecond[epochId]);
                }

                uint256 _generatedReward = _toTime
                    .sub(epochEndTimes[epochId - 1])
                    .mul(epochPolyPerSecond[epochId]);
                if (epochId == 1) {
                    return
                        _generatedReward.add(
                            epochEndTimes[0].sub(_fromTime).mul(
                                epochPolyPerSecond[0]
                            )
                        );
                }
                for (epochId = epochId - 1; epochId >= 1; --epochId) {
                    if (_fromTime >= epochEndTimes[epochId - 1]) {
                        return
                            _generatedReward.add(
                                epochEndTimes[epochId].sub(_fromTime).mul(
                                    epochPolyPerSecond[epochId]
                                )
                            );
                    }
                    _generatedReward = _generatedReward.add(
                        epochEndTimes[epochId]
                            .sub(epochEndTimes[epochId - 1])
                            .mul(epochPolyPerSecond[epochId])
                    );
                }
                return
                    _generatedReward.add(
                        epochEndTimes[0].sub(_fromTime).mul(
                            epochPolyPerSecond[0]
                        )
                    );
            }
        }
        return _toTime.sub(_fromTime).mul(epochPolyPerSecond[0]);
    }

    // View function to see pending Polys on frontend.
    function pendingPoly(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accPolyPerShare = pool.accPolyPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 _PolyReward = _generatedReward.mul(pool.allocPoint).div(
                totalAllocPoint
            );
            accPolyPerShare = accPolyPerShare.add(
                _PolyReward.mul(1e18).div(tokenSupply)
            );
        }
        return user.amount.mul(accPolyPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 _PolyReward = _generatedReward.mul(pool.allocPoint).div(
                totalAllocPoint
            );
            pool.accPolyPerShare = pool.accPolyPerShare.add(
                _PolyReward.mul(1e18).div(tokenSupply)
            );
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user
                .amount
                .mul(pool.accPolyPerShare)
                .div(1e18)
                .sub(user.rewardDebt);
            if (_pending > 0) {
                safePolyTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPolyPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accPolyPerShare).div(1e18).sub(
            user.rewardDebt
        );
        if (_pending > 0) {
            safePolyTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accPolyPerShare).div(1e18);
        emit Withdraw(_sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe Poly transfer function, just in case if rounding error causes pool to not have enough Polys.
    function safePolyTransfer(address _to, uint256 _amount) internal {
        uint256 _PolyBal = Poly.balanceOf(address(this));
        if (_PolyBal > 0) {
            if (_amount > _PolyBal) {
                Poly.safeTransfer(_to, _PolyBal);
            } else {
                Poly.safeTransfer(_to, _amount);
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyOperator {
        if (block.timestamp < epochEndTimes[1] + 30 days) {
            // do not allow to drain token if less than 30 days after farming
            require(_token != Poly, "!Poly");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "!pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}

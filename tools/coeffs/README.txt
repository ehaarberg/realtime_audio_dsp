FPGA coefficient export

Position: P1
Band: mid
Preset number: 4
Preset label: B_strong
Acceptance status: accepted_safe_below_goal
Sample time Ts: 2.0833333333333333e-05
Sample rate fs: 48000
Number of states: 20

Plant realization convention
x_next = A*x + B*u
y = C*x + D*u

Observer convention
xhat_next = A*xhat + B*u_known + g*L*(y - yhat)
yhat = C*xhat + D*u_known

Controller convention
u_ctrl = -K*xhat
If a reference or monitor-send signal r is used, use u = r + u_ctrl, equivalently u = r - K*xhat.

Important sign note
K is exported exactly as stored in the controller bank.
Do not negate K again if the FPGA implements u_ctrl = -K*xhat.

Fixed point export
Signed integer word length: 32
Fraction bits: 22
Real value = integer_value / 2^22

No fixed point saturation detected.

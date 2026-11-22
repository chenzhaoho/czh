# SKY130 dfxtp_1 Characterization

- Cell: `sky130_fd_sc_hd__dfxtp_1`
- Corner: `tt_025C_1v80`
- Standard-cell revision: `ac7fb61f06e6470b94e8afdf7c25268f62fbd7b1`
- Transistor-model revision: `f62031a1be9aefe902d6d54cddd6f59b57627436`
- Cell area: 20.0192 um^2
- Cell leakage: 0.00843863 uW
- D / CLK input capacitance: 1.6780 / 1.7940 fF
- Setup table range: -96.67 to 620.68 ps
- Hold table range: -517.81 to 140.95 ps
- Clock-to-Q table range: 265.24 to 1559.92 ps

## MTBF Parameters

tau = 9.01 ps, T_w = 451.97 ps, R^2 = 0.9962; source: behavioral model (NOT a SPICE characterization).

The setup, hold, and clock-to-Q figures above are ranges across the Liberty slew/load tables. They are not single fixed values and must be interpolated at the intended transition and load conditions for a timing budget. Clock skew and inter-stage routing delay come from the implementation, not this cell library.

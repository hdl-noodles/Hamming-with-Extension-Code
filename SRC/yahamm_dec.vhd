-------------------------------------------------------------------------------
-- Yahamm IP core
--
-- This file is part of the Yahamm project
-- http://www.opencores.org/cores/yahamm
--
-- Description
-- A hamming encoder and decoder with single-error correcting and
-- double-error detecting capability. The message length can be configured
-- through a generic. Both the code generator matrix and the parity-check
-- matrix are computed in the VHDL itself.
--
-- Author:
-- - Nicola De Simone, ndesimone@opencores.org
--
-------------------------------------------------------------------------------
--
-- Copyright (C) 2017 Authors and OPENCORES.ORG
--
-- This source file may be used and distributed without
-- restriction provided that this copyright statement is not
-- removed from the file and that any derivative work contains
-- the original copyright notice and the associated disclaimer.
--
-- This source file is free software; you can redistribute it
-- and/or modify it under the terms of the GNU Lesser General
-- Public License as published by the Free Software Foundation;
-- either version 2.1 of the License, or (at your option) any
-- later version.
--
-- This source is distributed in the hope that it will be
-- useful, but WITHOUT ANY WARRANTY; without even the implied
-- warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
-- PURPOSE. See the GNU Lesser General Public License for more
-- details.
--
--- You should have received a copy of the GNU Lesser General
-- Public License along with this source; if not, download it
-- from http://www.opencores.org/lgpl.shtml
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library yahamm;
use yahamm.matrix_pkg.all;
use yahamm.yahamm_pkg.all;

library std;
use std.textio.all;

-- There are two monitor counters:
--
-- cnt_errors_corrected: number of error correction performed.
-- cnt_errors_detected: numbers of errors detected but not corrected.
--
-- The two never count together and they don't overflow.  If CORRECT
-- is false, no correction is performed cnt_errors_corrected never counts.
-- If CORRECT is true and EXTRA_PARITY_BIT is true, cnt_errors_detected
-- never counts because all errors (supposedly single-bit errors) are
-- corrected.
--
-- ERROR_LEN: width of the cnt_errors_corrected and cnt_errors_detected counters.
--
-- nack_o: dout data valid, it's the en input pipelined.  It takes into
-- account the total latency.
--
entity yahamm_dec is
  generic (
    MESSAGE_LENGTH       : natural := 5;
    CORRECT : boolean := true;
    EXTRA_PARITY_BIT : natural range 0 to 1 := 1;
    ONE_PARITY_BIT : boolean := false;
    ERROR_LEN : natural := 16;
    OUTPUT_REG : boolean := false
    );
  port(
    clk_i, rst_i : in  std_logic;
    data_i     : in  std_logic_vector(MESSAGE_LENGTH - 1 downto 0);  -- Input data.
    parity_i   : in std_logic_vector(calc_nparity_bits(MESSAGE_LENGTH, ONE_PARITY_BIT) + EXTRA_PARITY_BIT - 1 downto 0);    -- Parity bits.
    data_o     : out std_logic_vector(MESSAGE_LENGTH - 1 downto 0);  -- Out data.
    nack_o     : out std_logic                                          -- data_o valid.
    );

end yahamm_dec;

architecture std of yahamm_dec is

  constant NPARITY_BITS : natural := calc_nparity_bits(MESSAGE_LENGTH, ONE_PARITY_BIT);
  constant BLOCK_LENGTH : natural := calc_block_length(MESSAGE_LENGTH, ONE_PARITY_BIT);

  constant H : matrix_t(0 to NPARITY_BITS + EXTRA_PARITY_BIT - 1,
                        0 to BLOCK_LENGTH + EXTRA_PARITY_BIT - 1) :=
    get_parity_check_matrix(MESSAGE_LENGTH, EXTRA_PARITY_BIT, ONE_PARITY_BIT);

  signal data_i_padded : bit_vector(BLOCK_LENGTH - NPARITY_BITS - 1 downto 0);
  signal code_sys, code_nonsys, code_nonsys_q : bit_vector(BLOCK_LENGTH + EXTRA_PARITY_BIT - 1 downto 0);
  signal syndrome : bit_vector(NPARITY_BITS + EXTRA_PARITY_BIT - 1 downto 0);
  signal wrong_bit : integer range 0 to code_sys'length;

  constant SWAPM : matrix_t(0 to BLOCK_LENGTH + EXTRA_PARITY_BIT - 1,
                            0 to BLOCK_LENGTH + EXTRA_PARITY_BIT - 1) :=
    get_form_swap_matrix(MESSAGE_LENGTH, EXTRA_PARITY_BIT, ONE_PARITY_BIT);

  signal correction_en : boolean;

begin

  check_parameters(BLOCK_LENGTH, NPARITY_BITS, MESSAGE_LENGTH, EXTRA_PARITY_BIT, ONE_PARITY_BIT, CORRECT);


  -- Pad data_i with zeros on the left, so that data_i_padded'length = BLOCK_LENGTH.
  -- This allow the user to reduce data_i width.
  data_i_padded(MESSAGE_LENGTH - 1 downto 0) <= to_bitvector(data_i);
  gen_padding: if BLOCK_LENGTH - NPARITY_BITS > MESSAGE_LENGTH generate
    data_i_padded(BLOCK_LENGTH - NPARITY_BITS - 1 downto MESSAGE_LENGTH) <= (others => '0');
  end generate gen_padding;

  -- Wire data and parity inputs in the systematic code code_sys (data
  -- on LSB, parity on MSB).
  code_sys <= to_bitvector(parity_i) & data_i_padded;

  -- Get the non-systematic code code_nonsys by swapping the
  -- systematic code code_sys.  The non-systematic code is needed to
  -- obtain an immediately meaningful syndrome.  This is timing-safe:
  -- no logic here, it's purely wiring.
  code_nonsys <= xor_multiply_vec(SWAPM, code_sys);


  -- purpose: Compute error syndrome from the non-systematic code
  -- (input) and the non-systemacic parity check matrix H.  Also delay
  -- code_nonsys to have code_nonsys_q synchronous with syndrome.  And start
  -- pipelining en input.
  -- type   : sequential
  -- inputs : clk_i, rst_i, code_nonsys
  -- outputs: syndrome
  out_reg: if OUTPUT_REG generate
    syndrome_proc: process (clk_i, rst_i) is
    begin  -- process syndrome_proc
      if rst_i = '1' then                   -- asynchronous reset (active high)
        syndrome <= (others => '0');
        code_nonsys_q <= (others => '0');
      elsif rising_edge(clk_i) then         -- rising clock edge
        syndrome <= xor_multiply_vec(H, code_nonsys);
        code_nonsys_q <= code_nonsys;
      end if;
    end process syndrome_proc;
  end generate out_reg;
  no_out_reg: if (not OUTPUT_REG) generate
    syndrome_proc: process (all) is
    begin  -- process syndrome_proc
      syndrome <= xor_multiply_vec(H, code_nonsys);
      code_nonsys_q <= code_nonsys;
    end process syndrome_proc;
  end generate no_out_reg;

  -- purpose: Enable error correction (signal correction_en) for a single bit
  -- error.  Dependent from the generic parameters.  If correction is enabled
  -- wrong_bit signal is assigned the position of the wrong bit.
  -- type   : combinational
  -- inputs : syndrome
  -- outputs: correction_enabled
  correction_enable_proc: process (syndrome) is
  begin  -- process correction_enable_proc
    wrong_bit <= 0;

    --case CORRECT is
      --when false =>
        ---- Entity does not implement correction.
        --correction_en <= false;

      --when true =>
        -- Entity implements correction.

        case EXTRA_PARITY_BIT is
          when 0 =>
            -- SEC case (see table).  Always correct.
            correction_en <= true;

            -- The wrong bit is the syndrome itself.
            wrong_bit <= to_integer(unsigned(To_StdULogicVector(syndrome)));

          when 1 =>
            -- SECDED case (see table).  The error, if any, is a single error to be
            -- corrected if the extra parity bit in the syndrome is '1'.
            if syndrome(syndrome'high) = '0' then
              -- Double error: don't correct.
              correction_en <= false;
            else
              -- Single error: correct.
              correction_en <= true;

              -- The wrong bit is not just the syndrome, because the
              -- syndrome has the extra parity bit as MSB bit.
              if or_reduce(syndrome(syndrome'high-1 downto 0)) = '0' then
                -- No other error.  So the extra parity bit itself is
                -- wrong, that in this implementation is the MSB of
                -- the non-systematic code word.
                wrong_bit <= code_nonsys_q'length;
              else
                -- Extra parity bit '1', ignore it for wrong_bit position.
                wrong_bit <= to_integer(unsigned(To_StdULogicVector(syndrome(NPARITY_BITS-1 downto 0))));
              end if;
            end if;
        end case;

    --end case;

  end process correction_enable_proc;

  -- purpose: Decode the non systematic code code_nonsys_q and drive
  -- output data_o.  Single error correction is performed, depending on
  -- the configuration.
  -- type   : sequential
  -- inputs : clk_i, rst_i, code_nonsys_q, syndrome
  -- outputs: data_o
  out_reg2: if OUTPUT_REG generate
    decode_proc: process (clk_i, rst_i) is
      variable iserror : boolean;         -- parity error condition
      variable code_sys_dec, code_nonsys_dec : bit_vector(code_sys'range);
    begin  -- process decode_proc
      if rst_i = '1' then                   -- asynchronous reset (active high)
        data_o <= (others => '0');
        nack_o <= '0';
      elsif rising_edge(clk_i) then         -- rising clock edge

          code_nonsys_dec := code_nonsys_q;
          iserror := or_reduce(syndrome) = '1';

          if correction_en and iserror then
              code_nonsys_dec(wrong_bit-1) := not code_nonsys_q(wrong_bit-1);
            --end if;
          end if;

          code_sys_dec := xor_multiply_vec(SWAPM, code_nonsys_dec);
          data_o <= To_StdLogicVector(code_sys_dec(MESSAGE_LENGTH - 1 downto 0));
          if iserror and  not correction_en then
            nack_o <= '1';
          else
            nack_o <= '0';
          end if;

        end if;
    end process decode_proc;
  end generate out_reg2;
  no_out_reg2: if (not OUTPUT_REG) generate
    decode_proc: process (all) is
      variable iserror : boolean;         -- parity error condition
      variable code_sys_dec, code_nonsys_dec : bit_vector(code_sys'range);
    begin  -- process decode_proc


        code_nonsys_dec := code_nonsys_q;
        iserror := or_reduce(syndrome) = '1';

        if correction_en and iserror then
            --if ( wrong_bit > 0 ) then
          code_nonsys_dec(wrong_bit-1) := not code_nonsys_q(wrong_bit-1);
        --end if;
        end if;

        code_sys_dec := xor_multiply_vec(SWAPM, code_nonsys_dec);
        data_o <= To_StdLogicVector(code_sys_dec(MESSAGE_LENGTH - 1 downto 0));
        if iserror and  not correction_en then
          nack_o <= '1';
        else
          nack_o <= '0';
        end if;

    end process decode_proc;
  end generate no_out_reg2;

end architecture std;

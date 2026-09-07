----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Design Name: 
-- Module Name: lsu - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity lsu is
    generic (
        WORDS        : positive := 8; -- M, L or M*L
        DATA_WIDTH   : positive := 64
    );
    port (
       
        lsu_en_i     : in  std_logic;
        addr_idx_i   : in  integer range 0 to WORDS-1; -- the counter value coming from the controller
        
        sram_addr_o  : out std_logic_vector(integer(ceil(log2(real(WORDS))))-1 downto 0); 
        sram_cs_o    : out std_logic;
        
        data_in_i    : in  std_logic_vector(DATA_WIDTH-1 downto 0);
        data_out_o   : out std_logic_vector(DATA_WIDTH-1 downto 0)

    );
end lsu;

architecture Behavioral of lsu is
begin

    sram_addr_o <= std_logic_vector(to_unsigned(addr_idx_i, sram_addr_o'length));-- takes the integer (addr_idx_i) and converted 

    sram_cs_o   <= lsu_en_i; --cs follows the LSU enable signal
    
    data_out_o  <= data_in_i;-- data from the SRAM or dot product

end Behavioral;

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library std;
use std.env.all;

use work.pProc_bus_gba.all;
use work.pRegmap_gba.all;
use work.pReg_savestates.all;

-- Direct Boot checks for gba_savestates.
--
-- The unit runs against the five savestate registers a direct boot presets,
-- a memory bus model that classifies every write, and a savestate storage
-- model. Each scenario runs in a fresh elaboration.
entity tb_gba_savestates_directboot is
   generic
   (
      SCENARIO : natural := 0
   );
end entity;

architecture test of tb_gba_savestates_directboot is

   constant CLK_PERIOD      : time := 10 ns;
   constant STATESIZE       : natural := 16#18346#;
   -- EWRAM, IWRAM, palette, VRAM, OAM
   constant CLEAR_WORDS     : natural := 65536 + 8192 + 256 + 24576 + 256;
   constant IOREG_WORDS     : natural := 256;
   constant MEM_LATENCY     : positive := 2;
   constant STORAGE_LATENCY : positive := 3;

   -- PC value the storage model's pattern loads
   constant LOADED_PC       : std_logic_vector(31 downto 0) := x"10000002";

   signal clk         : std_logic := '0';
   signal gb_on       : std_logic := '0';
   signal load        : std_logic := '0';
   signal direct_boot : std_logic := '0';
   signal bad_header  : boolean := false;

   signal reset       : std_logic;
   signal load_done   : std_logic;
   signal busy        : std_logic;
   signal loading     : std_logic;
   signal saving      : std_logic;
   signal sleep       : std_logic;

   signal savestate_bus : proc_bus_gb_type;
   signal gb_bus        : proc_bus_gb_type;

   signal SAVE_BusAddr      : std_logic_vector(27 downto 0);
   signal SAVE_BusRnW       : std_logic;
   signal SAVE_BusACC       : std_logic_vector(1 downto 0);
   signal SAVE_BusWriteData : std_logic_vector(31 downto 0);
   signal SAVE_Bus_ena      : std_logic;
   signal SAVE_BusReadDone  : std_logic := '0';

   signal bus_out_Din    : std_logic_vector(63 downto 0);
   signal bus_out_Dout   : std_logic_vector(63 downto 0) := (others => '0');
   signal bus_out_Adr    : std_logic_vector(25 downto 0);
   signal bus_out_rnw    : std_logic;
   signal bus_out_ena    : std_logic;
   signal bus_out_active : std_logic;
   signal bus_out_be     : std_logic_vector(7 downto 0);
   signal bus_out_done   : std_logic := '0';

   -- the registers a direct boot presets
   signal reg_pc     : std_logic_vector(31 downto 0);
   signal reg_sp     : std_logic_vector(31 downto 0);
   signal reg_sp_irq : std_logic_vector(31 downto 0);
   signal reg_sp_svc : std_logic_vector(31 downto 0);
   signal reg_mixed  : std_logic_vector(REG_SAVESTATE_CPUMIXED.upper downto REG_SAVESTATE_CPUMIXED.lower);

   -- bookkeeping
   signal cyc                : natural := 0;
   signal reset_count        : natural := 0;
   signal irst_count         : natural := 0;
   signal load_done_count    : natural := 0;
   signal busy_falls         : natural := 0;
   signal internal_writes    : natural := 0;
   signal storage_requests   : natural := 0;
   signal clear_writes       : natural := 0;
   signal clear_order_errors : natural := 0;
   signal load_mem_writes    : natural := 0;
   signal ioreg_writes       : natural := 0;
   signal protocol_errors    : natural := 0;

   -- first cycle after switch-on in which the CPU may run
   signal awake_valid        : boolean := false;
   signal awake_reset        : std_logic := '0';
   signal awake_load_done    : std_logic := '0';

   function is_modelled(adr : std_logic_vector) return boolean is
      type t_adrs is array(natural range <>) of natural;
      constant adrs : t_adrs :=
      (
         REG_SAVESTATE_PC.Adr,
         REG_SAVESTATE_REGS.Adr + 13,
         REG_SAVESTATE_REGS_2_13.Adr,
         REG_SAVESTATE_REGS_3_13.Adr,
         REG_SAVESTATE_CPUMIXED.Adr
      );
   begin
      for i in adrs'range loop
         if adr = std_logic_vector(to_unsigned(adrs(i), adr'length)) then
            return true;
         end if;
      end loop;
      return false;
   end function;

   -- address of the n-th word a direct boot clears
   function clear_addr(position : natural) return std_logic_vector is
      variable p    : natural := position mod CLEAR_WORDS;
      variable base : unsigned(27 downto 0);
   begin
      if p < 65536 then
         base := x"2000000";
      elsif p < 65536 + 8192 then
         base := x"3000000"; p := p - 65536;
      elsif p < 65536 + 8192 + 256 then
         base := x"5000000"; p := p - (65536 + 8192);
      elsif p < 65536 + 8192 + 256 + 24576 then
         base := x"6000000"; p := p - (65536 + 8192 + 256);
      else
         base := x"7000000"; p := p - (65536 + 8192 + 256 + 24576);
      end if;
      return std_logic_vector(base + to_unsigned(p * 4, 28));
   end function;

begin

   clk <= not clk after CLK_PERIOD / 2;

   -- idle GBA bus
   gb_bus <= (Din  => (others => '0'),
              Dout => (others => 'Z'),
              Adr  => (others => '0'),
              rnw  => '1',
              ena  => '0',
              done => 'Z',
              acc  => "00",
              bEna => "0000",
              rst  => '0');

   -- unmodelled savestate registers acknowledge at once
   savestate_bus.done <= 'Z' when is_modelled(savestate_bus.Adr) else '1';

   iREG_PC     : entity work.eProcReg_gba generic map (REG_SAVESTATE_PC)        port map (clk, savestate_bus, reg_pc    , reg_pc);
   iREG_SP     : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS, 13)  port map (clk, savestate_bus, reg_sp    , reg_sp);
   iREG_SP_IRQ : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_2_13) port map (clk, savestate_bus, reg_sp_irq, reg_sp_irq);
   iREG_SP_SVC : entity work.eProcReg_gba generic map (REG_SAVESTATE_REGS_3_13) port map (clk, savestate_bus, reg_sp_svc, reg_sp_svc);
   iREG_MIXED  : entity work.eProcReg_gba generic map (REG_SAVESTATE_CPUMIXED)  port map (clk, savestate_bus, reg_mixed , reg_mixed);

   dut : entity work.gba_savestates
   generic map
   (
      Softmap_GBA_WRam_ADDR   => 0,
      Softmap_GBA_FLASH_ADDR  => 0,
      Softmap_GBA_EEPROM_ADDR => 0
   )
   port map
   (
      clk100                => clk,
      gb_on                 => gb_on,
      reset                 => reset,

      load_done             => load_done,

      increaseSSHeaderCount => '0',
      save                  => '0',
      load                  => load,
      direct_boot           => direct_boot,
      savestate_address     => 0,
      savestate_busy        => busy,

      cpu_jump              => '0',

      internal_bus_out      => savestate_bus,
      loading_savestate     => loading,
      saving_savestate      => saving,
      sleep_savestate       => sleep,
      bus_ena_in            => '0',

      gb_bus                => gb_bus,

      SAVE_BusAddr          => SAVE_BusAddr,
      SAVE_BusRnW           => SAVE_BusRnW,
      SAVE_BusACC           => SAVE_BusACC,
      SAVE_BusWriteData     => SAVE_BusWriteData,
      SAVE_Bus_ena          => SAVE_Bus_ena,

      SAVE_BusReadData      => (others => '0'),
      SAVE_BusReadDone      => SAVE_BusReadDone,

      bus_out_Din           => bus_out_Din,
      bus_out_Dout          => bus_out_Dout,
      bus_out_Adr           => bus_out_Adr,
      bus_out_rnw           => bus_out_rnw,
      bus_out_ena           => bus_out_ena,
      bus_out_active        => bus_out_active,
      bus_out_be            => bus_out_be,
      bus_out_done          => bus_out_done
   );

   -- Bus models and bookkeeping.
   models : process (clk)
      variable mem_delay     : natural := 0;
      variable storage_delay : natural := 0;
      variable gb_on_q       : std_logic := '0';
      variable busy_q        : std_logic := '0';
      variable awake_seen    : boolean := false;
   begin
      if rising_edge(clk) then

         cyc <= cyc + 1;

         if reset = '1' then reset_count <= reset_count + 1; end if;
         if savestate_bus.rst = '1' then irst_count <= irst_count + 1; end if;
         if load_done = '1' then load_done_count <= load_done_count + 1; end if;
         if busy_q = '1' and busy = '0' then busy_falls <= busy_falls + 1; end if;
         busy_q := busy;

         if savestate_bus.ena = '1' and savestate_bus.rnw = '0' then
            internal_writes <= internal_writes + 1;
         end if;

         -- the CPU steps whenever the core is on and not asleep
         if gb_on = '1' and gb_on_q = '0' then
            awake_seen  := false;
            awake_valid <= false;
         end if;
         if gb_on = '1' and sleep = '0' and not awake_seen then
            awake_seen      := true;
            awake_valid     <= true;
            awake_reset     <= reset;
            awake_load_done <= load_done;
         end if;
         gb_on_q := gb_on;

         -- memory bus: writes only, acknowledged after MEM_LATENCY
         SAVE_BusReadDone <= '0';
         if SAVE_Bus_ena = '1' then
            if SAVE_BusRnW /= '0' or mem_delay /= 0 then
               protocol_errors <= protocol_errors + 1;
            end if;
            if SAVE_BusAddr(27 downto 24) = x"4" then
               ioreg_writes <= ioreg_writes + 1;
            elsif SAVE_BusWriteData = x"00000000" then
               if SAVE_BusAddr /= clear_addr(clear_writes) then
                  clear_order_errors <= clear_order_errors + 1;
               end if;
               clear_writes <= clear_writes + 1;
            else
               load_mem_writes <= load_mem_writes + 1;
            end if;
            mem_delay := MEM_LATENCY;
         elsif mem_delay > 1 then
            mem_delay := mem_delay - 1;
         elsif mem_delay = 1 then
            mem_delay := 0;
            SAVE_BusReadDone <= '1';
         end if;

         -- savestate storage: valid header, then a non-zero pattern
         bus_out_done <= '0';
         if bus_out_ena = '1' then
            storage_requests <= storage_requests + 1;
            if storage_delay /= 0 then
               protocol_errors <= protocol_errors + 1;
            end if;
            storage_delay := STORAGE_LATENCY;
         elsif storage_delay > 1 then
            storage_delay := storage_delay - 1;
         elsif storage_delay = 1 then
            storage_delay := 0;
            bus_out_done  <= '1';
            if unsigned(bus_out_Adr) = 0 then
               if bad_header then
                  bus_out_Dout <= x"DEADBEEF" & x"00000001";
               else
                  bus_out_Dout <= std_logic_vector(to_unsigned(STATESIZE, 32)) & x"00000001";
               end if;
            else
               bus_out_Dout <= std_logic_vector'(x"2" & "00") & bus_out_Adr &
                               std_logic_vector'(x"1" & "00") & bus_out_Adr;
            end if;
         end if;

      end if;
   end process;

   stimulus : process

      variable t0          : natural;
      variable boot_cycles : natural;
      variable load_cycles : natural;
      variable n           : natural;

      procedure tick(count : natural := 1) is
      begin
         for i in 1 to count loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure check(ok : boolean; what : string) is
      begin
         assert ok report "scenario " & integer'image(SCENARIO) & ": " & what severity error;
      end procedure;

      procedure wait_cycle(target : natural) is
      begin
         while cyc < target loop
            tick;
         end loop;
      end procedure;

      procedure wait_idle is
         variable waited : natural := 0;
      begin
         while busy /= '0' loop
            tick;
            waited := waited + 1;
            assert waited < 4_000_000 report "timeout waiting for savestate_busy to fall" severity failure;
         end loop;
         tick(2); -- let the bookkeeping see the final cycle
      end procedure;

      procedure power_on is
      begin
         gb_on <= '1';
         tick(3);
      end procedure;

      procedure power_off is
      begin
         gb_on <= '0';
         tick(50);
      end procedure;

      procedure request_load is
      begin
         load <= '1';
         tick;
         load <= '0';
         tick(2);
      end procedure;

      procedure check_direct_boot_registers is
      begin
         check(reg_pc     = x"08000000", "PC is not the cartridge entry point");
         check(reg_sp     = x"03007F00", "System stack pointer is wrong");
         check(reg_sp_irq = x"03007FA0", "IRQ stack pointer is wrong");
         check(reg_sp_svc = x"03007FE0", "Supervisor stack pointer is wrong");
         check(reg_mixed  = x"3C0",      "CPU is not in System mode / ARM state");
      end procedure;

      procedure check_default_registers is
      begin
         check(reg_pc    = x"00000000", "PC is not at the BIOS reset vector");
         check(reg_mixed = x"CC0",      "CPU mode is not the reset default");
      end procedure;

      -- completed direct boot: RAM cleared once more, CPU first ran on the closing reset
      procedure check_direct_boot(boots : natural) is
      begin
         check(busy = '0' and sleep = '0' and loading = '0', "direct boot did not finish cleanly");
         check(clear_writes = boots * CLEAR_WORDS, "RAM clear is incomplete or repeated");
         check(clear_order_errors = 0, "RAM clear addresses are out of order");
         check(protocol_errors = 0, "bus protocol violated");
         check_direct_boot_registers;
         check(awake_valid and awake_reset = '1', "CPU ran before the direct boot state was applied");
      end procedure;

      procedure check_bios_boot is
      begin
         check(busy = '0' and sleep = '0' and loading = '0', "core is not running normally");
         check(awake_valid and awake_reset = '0', "CPU did not start straight away");
      end procedure;

   begin

      tick(50);
      check(busy = '0', "power-on reset sequence did not finish");
      check(reset_count = 1 and irst_count = 1, "power-on reset sequence did not run once");

      case SCENARIO is

         -- Direct boot off: nothing changes.
         when 0 =>
            check(sleep = '0', "CPU asleep although direct boot is off");
            power_on;
            tick(500);
            check_bios_boot;
            check(clear_writes = 0 and load_mem_writes = 0 and ioreg_writes = 0, "memory written without direct boot");
            check(internal_writes = 0 and storage_requests = 0, "savestate registers or storage touched");
            check_default_registers;
            check(reset_count = 1, "unexpected reset pulse");
            power_off;
            check(reset_count = 2 and irst_count = 2, "reset sequence did not run on switch-off");
            check(sleep = '0', "CPU asleep although direct boot is off");

         -- Cold direct boot, then Reset Core.
         when 1 =>
            direct_boot <= '1';
            tick(50);
            check(sleep = '1' and busy = '0', "CPU is not held asleep before switch-on");
            t0 := cyc;
            power_on;
            wait_idle;
            boot_cycles := cyc - t0;
            check_direct_boot(1);
            check(internal_writes = 5, "wrong number of savestate registers preset");
            check(storage_requests = 0 and load_mem_writes = 0 and ioreg_writes = 0, "direct boot read savestate storage");
            check(reset_count = 2 and load_done_count = 0, "direct boot did not end with exactly one reset pulse");
            tick(1000);
            check_direct_boot(1);
            report "direct boot took " & integer'image(boot_cycles) & " cycles with a " &
                   integer'image(MEM_LATENCY) & "-cycle memory model";

            power_off;
            check_default_registers;
            check(sleep = '1' and reset_count = 3, "switch-off did not reset and re-arm");
            power_on;
            wait_idle;
            check_direct_boot(2);
            check(reset_count = 4, "second direct boot did not end with one reset pulse");

         -- The setting is only acted on while the core is off.
         when 2 =>
            power_on;
            tick(200);
            direct_boot <= '1';
            tick(2000);
            check_bios_boot;
            check(clear_writes = 0, "enabling direct boot disturbed a running game");

            power_off;
            check(sleep = '1', "direct boot not armed after reset");
            power_on;
            wait_idle;
            check_direct_boot(1);

            direct_boot <= '0';
            tick(2000);
            check(sleep = '0' and busy = '0', "disabling direct boot disturbed a running game");
            power_off;
            check(sleep = '0', "direct boot still armed after it was disabled");
            check_default_registers;
            power_on;
            tick(500);
            check_bios_boot;
            check(clear_writes = CLEAR_WORDS, "RAM cleared although direct boot is off");
            check_default_registers;

            -- enabled and disabled again while off
            power_off;
            direct_boot <= '1';
            tick(10);
            check(sleep = '1', "direct boot not armed while off");
            direct_boot <= '0';
            tick(10);
            check(sleep = '0', "direct boot not disarmed while off");
            power_on;
            tick(500);
            check_bios_boot;
            check(clear_writes = CLEAR_WORDS, "RAM cleared although direct boot is off");

         -- A savestate load requested during the direct boot is not lost.
         when 3 =>
            direct_boot <= '1';
            tick(50);
            n := busy_falls;
            power_on;
            while clear_writes < 1000 loop
               tick;
            end loop;
            check(busy = '1' and sleep = '1' and loading = '1', "direct boot is not in progress");
            request_load;
            wait_idle;
            check(clear_writes = CLEAR_WORDS and clear_order_errors = 0, "direct boot did not complete first");
            check(load_done_count = 1, "savestate load requested during direct boot was lost");
            check(load_mem_writes = CLEAR_WORDS and ioreg_writes = IOREG_WORDS, "savestate was not loaded completely");
            check(reg_pc = LOADED_PC, "loaded CPU state was not applied");
            check(busy_falls = n + 1, "savestate_busy dropped between direct boot and load");
            check(awake_valid and awake_reset = '1' and awake_load_done = '1', "CPU ran before the savestate was loaded");
            check(sleep = '0' and protocol_errors = 0, "load did not finish cleanly");

            -- requests around the end of the direct boot
            power_off;
            t0 := cyc;
            power_on;
            wait_idle;
            boot_cycles := cyc - t0;
            for early in -4 to 8 loop
               power_off;
               n  := load_done_count;
               t0 := cyc;
               power_on;
               wait_cycle(t0 + boot_cycles - early);
               request_load;
               wait_idle;
               check(load_done_count = n + 1,
                     "savestate load requested " & integer'image(early) & " cycles before the end of direct boot was lost");
               check(reg_pc = LOADED_PC and sleep = '0', "loaded CPU state was not applied");
            end loop;
            check(protocol_errors = 0 and clear_order_errors = 0, "bus protocol violated");

         -- A savestate loaded while the core is off is not overwritten.
         when 4 =>
            direct_boot <= '1';
            tick(50);
            check(sleep = '1', "direct boot not armed");
            t0 := cyc;
            request_load;
            wait_idle;
            load_cycles := cyc - t0;
            check(load_done_count = 1 and reg_pc = LOADED_PC, "savestate was not loaded while off");
            tick(100);
            power_on;
            tick(2000);
            check(busy = '0' and sleep = '0', "core is not running the loaded state");
            check(clear_writes = 0 and reg_pc = LOADED_PC, "direct boot overwrote the loaded savestate");

            -- the next reset boots directly again
            power_off;
            check_default_registers;
            check(sleep = '1', "direct boot not re-armed by reset");
            power_on;
            wait_idle;
            check_direct_boot(1);

            -- switch-on around the end of the load
            for late in -6 to 5 loop
               power_off;
               n  := clear_writes;
               t0 := cyc;
               load <= '1';
               tick;
               load <= '0';
               wait_cycle(t0 + load_cycles + late);
               power_on;
               wait_idle;
               tick(2000);
               check(busy = '0' and sleep = '0', "core is not running the loaded state");
               check(clear_writes = n and reg_pc = LOADED_PC,
                     "direct boot overwrote a savestate when switched on " & integer'image(late) & " cycles after the load");
            end loop;
            check(protocol_errors = 0, "bus protocol violated");

         -- The core is switched off again during the direct boot.
         when 5 =>
            -- off at the end of the sequence, direct boot then disabled
            direct_boot <= '1';
            tick(50);
            power_on;
            while clear_writes < 1000 loop
               tick;
            end loop;
            gb_on <= '0';
            tick(3);
            wait_idle;
            tick(50);
            check(clear_writes = CLEAR_WORDS, "interrupted direct boot left the bus mid-sequence");
            check_default_registers;
            check(sleep = '1', "direct boot not re-armed");
            direct_boot <= '0';
            tick(10);
            power_on;
            tick(500);
            check_bios_boot;
            check_default_registers;
            check(clear_writes = CLEAR_WORDS, "RAM cleared although direct boot is off");

            -- off at the end of the sequence, direct boot still enabled
            power_off;
            direct_boot <= '1';
            tick(50);
            power_on;
            while clear_writes < CLEAR_WORDS + 1000 loop
               tick;
            end loop;
            gb_on <= '0';
            tick(3);
            wait_idle;
            tick(50);
            check(sleep = '1', "direct boot not re-armed");
            power_on;
            wait_idle;
            check_direct_boot(3);

            -- off and on again within the sequence
            power_off;
            power_on;
            while clear_writes < 3 * CLEAR_WORDS + 1000 loop
               tick;
            end loop;
            gb_on <= '0';
            tick(300);
            gb_on <= '1';
            tick(3);
            wait_idle;
            check_direct_boot(4);
            tick(1000);
            check_direct_boot(4);

         -- Ordinary savestate loads keep working with direct boot enabled.
         when 6 =>
            direct_boot <= '1';
            tick(50);
            power_on;
            wait_idle;
            check_direct_boot(1);

            request_load;
            wait_idle;
            check(load_done_count = 1 and reg_pc = LOADED_PC, "savestate load failed");
            check(load_mem_writes = CLEAR_WORDS and ioreg_writes = IOREG_WORDS, "savestate was not loaded completely");
            check(clear_writes = CLEAR_WORDS and sleep = '0', "savestate load triggered a direct boot");

            bad_header <= true;
            request_load;
            wait_idle;
            check(load_done_count = 1, "savestate with a bad header was accepted");
            check(sleep = '0' and busy = '0' and loading = '0', "rejected savestate left the core paused");
            bad_header <= false;

            power_off;
            check(sleep = '1', "direct boot not re-armed by reset");
            power_on;
            wait_idle;
            check_direct_boot(2);
            check(protocol_errors = 0, "bus protocol violated");

         when others =>
            report "unknown scenario" severity failure;

      end case;

      report "scenario " & integer'image(SCENARIO) & " passed";
      finish;

   end process;

end architecture;

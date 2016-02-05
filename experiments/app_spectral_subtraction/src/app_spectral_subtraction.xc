// Copyright (c) 2016, XMOS Ltd, All rights reserved
#include <xscope.h>
#include <platform.h>
#include <xs1.h>
#include <stdlib.h>
#include <print.h>
#include <stdio.h>
#include <string.h>
#include <xclib.h>
#include <stdint.h>
#include <math.h>
#include <limits.h>
#include <print.h>

#include "mic_array.h"
#include "mic_array_board_support.h"

#include "lib_dsp.h"

#include "i2c.h"
#include "i2s.h"

#include "beamforming.h"

#define DF 2    //Decimation Factor

on tile[0]:p_leds leds = DEFAULT_INIT;
on tile[0]:in port p_buttons =  XS1_PORT_4A;

on tile[0]: in port p_pdm_clk               = XS1_PORT_1E;
on tile[0]: in buffered port:32 p_pdm_mics  = XS1_PORT_8B;
on tile[0]: in port p_mclk                  = XS1_PORT_1F;
on tile[0]: clock pdmclk                    = XS1_CLKBLK_1;

out buffered port:32 p_i2s_dout[1]  = on tile[1]: {XS1_PORT_1P};
in port p_mclk_in1                  = on tile[1]: XS1_PORT_1O;
out buffered port:32 p_bclk         = on tile[1]: XS1_PORT_1M;
out buffered port:32 p_lrclk        = on tile[1]: XS1_PORT_1N;
out port p_pll_sync                 = on tile[1]: XS1_PORT_4D;
port p_i2c                          = on tile[1]: XS1_PORT_4E; // Bit 0: SCLK, Bit 1: SDA
port p_rst_shared                   = on tile[1]: XS1_PORT_4F; // Bit 0: DAC_RST_N, Bit 1: ETH_RST_N
clock mclk                          = on tile[1]: XS1_CLKBLK_3;
clock bclk                          = on tile[1]: XS1_CLKBLK_4;


#define FFT_N (1<<MAX_FRAME_SIZE_LOG2)

void output_frame(chanend c_audio, int proc_buffer[4][FFT_N/2], lib_dsp_fft_complex_t p[FFT_N],
        unsigned &head, int * window){

    lib_dsp_fft_rebuild_one_real_input(p, FFT_N);
    lib_dsp_fft_bit_reverse(p, FFT_N);
    lib_dsp_fft_inverse_complex(p, FFT_N, lib_dsp_sine_512);

    //apply the window function
    for(unsigned i=0;i<FFT_N/2;i++){
       long long t = (long long)window[i] * (long long)p[i].re;
       p[i].re = (t>>31);
    }
    for(unsigned i=FFT_N/2;i<FFT_N;i++){
       long long t = (long long)window[FFT_N-1-i] * (long long)p[i].re;
       p[i].re = (t>>31);
    }

    for(unsigned i=0;i<FFT_N/2;i++){
        proc_buffer[head][i] += p[i].re;
        proc_buffer[(head+1)%4][i] = p[i+FFT_N/2].re;
    }

    unsafe {
        c_audio <: (int * unsafe)(proc_buffer[head]);
    }
    head++;
    if(head == 4)
        head = 0;
}

{int, int} foo(int x, int y, unsigned old_h, unsigned new_h){

    unsigned long long t = (unsigned long long)new_h;

    if(!old_h)
        return {0, 0};

    if(!new_h)
        return {0, 0};

    if(x>0){
        unsigned long long v =t*(unsigned)x;
        x = v/old_h;
    } else {
        x=-x;
        unsigned long long v =t*(unsigned)x;
        x = v/old_h;
        x=-x;
    }

    if(y>0){
        unsigned long long v =t*(unsigned)y;
        y = v/old_h;
    } else {
        y=-y;
        unsigned long long v =t*(unsigned)y;
        y = v/old_h;
        y=-y;
    }
 /*
    if(old_h){
        x = (long long)x * (long long)new_h / (long long)old_h;
        y = (long long)y * (long long)new_h / (long long)old_h;
    }
*/
   return {x, y};
}

    int data_0[4*THIRD_STAGE_COEFS_PER_STAGE*DF] = {0};
    int data_1[4*THIRD_STAGE_COEFS_PER_STAGE*DF] = {0};

void noise_red(streaming chanend c_ds_output[2],
        client interface led_button_if lb, chanend c_audio){

    unsigned buffer ;     //buffer index
    frame_complex comp[4];
    memset(comp, 0, sizeof(frame_complex)*4);
    lib_dsp_fft_complex_t p[FFT_N];
    int window[FFT_N/2];
    for(unsigned i=0;i<FFT_N/2;i++){
         window[i] = (int)((double)INT_MAX*sqrt(0.5*(1.0 - cos(2.0 * 3.14159265359*(double)i / (double)(FFT_N-2)))));
    }

    unsafe{
        decimator_config_common dcc = {
                MAX_FRAME_SIZE_LOG2,
                1,
                1,
                window,
                DF,
                g_third_stage_div_2_fir,
                0,
                0,
                DECIMATOR_HALF_FRAME_OVERLAP,
                4

        };
        decimator_config dc[2] = {
                {&dcc, data_0, {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4},
                {&dcc, data_1, {INT_MAX, INT_MAX, INT_MAX, INT_MAX}, 4}
        };

        decimator_configure(c_ds_output, 2, dc);

        decimator_init_complex_frame(c_ds_output, 2, buffer, comp, dcc);

        int proc_buffer[4][FFT_N/2];

        memset(proc_buffer, 0, sizeof(int)*4*FFT_N/2);

        unsigned head = 0;

        unsigned long long lpf[FFT_N/2] = {0};
        int enabled = 0;

        while(1){
           frame_complex * current = decimator_get_next_complex_frame(c_ds_output, 2, buffer, comp, dcc);
           for(unsigned i=0;i<4;i++){
               lib_dsp_fft_forward_complex((lib_dsp_fft_complex_t*)current->data[i], FFT_N, lib_dsp_sine_512);
               lib_dsp_fft_reorder_two_real_inputs((lib_dsp_fft_complex_t*)current->data[i], FFT_N);
           }
           frame_frequency * frequency = (frame_frequency *)current;
           int noise = 1;

           long long sum = 0;

          // xscope_int(0, 0);
          // xscope_int(1, 0);

           #define FLOOR 5
           //  frequency->data[0][0].re>>=FLOOR;
          // frequency->data[0][0].im = 0;
           for(unsigned i=1; i<FFT_N/2-2;i++){

              int re = frequency->data[0][i].re;
              int im = frequency->data[0][i].im;

              unsigned mag = hypot_i(re, im);
              unsigned noise_floor = lpf[i]>>30;

            //  int32_t a, b;
            //  cordic(a, b, a, b);

             // xscope_int(0,mag);
             // xscope_int(1, noise_floor);
              if(enabled){
                  noise_floor=noise_floor>>2;
                  if(mag > noise_floor){

                     unsigned new_mag = mag - noise_floor;

                     if(mag > 0){
                         if((mag>>FLOOR) > new_mag)
                             new_mag = (mag>>FLOOR);
                     } else {
                         if((mag>>FLOOR) < new_mag)
                             new_mag = (mag>>FLOOR);
                     }

                     //xscope_int(2, new_mag);
                     {re, im} = foo(re, im, mag, new_mag);

                     frequency->data[0][i].re = re;
                     frequency->data[0][i].im = im;
                  }
                  else {
                      unsigned new_mag = noise_floor - mag;
                      if(mag > 0){
                          if((mag>>FLOOR) > new_mag)
                              new_mag = (mag>>FLOOR);
                      } else {
                          if((mag>>FLOOR) < new_mag)
                              new_mag = (mag>>FLOOR);
                      }

                      {re, im} = foo(re, im, mag, new_mag);

                     // xscope_int(2, new_mag);
                      frequency->data[0][i].re = re;
                      frequency->data[0][i].im = im;
                  }
              }

              unsigned long long h = (unsigned long long)mag;
              unsigned s = 8;
              h <<= (30 - s);
              lpf[i] = lpf[i] - (lpf[i]>>s) + h;

           }

           select {
               case lb.button_event():{
                   unsigned button;
                   e_button_state pressed;
                   lb.get_button_event(button, pressed);
                   if(pressed == BUTTON_PRESSED){
                       enabled = 1-enabled;
                       printf("%d\n", enabled);
                   }
                   break;
               }
               default:break;
           }

           for(unsigned i=0;i<FFT_N/2;i++){
               if(enabled){
                   p[i].re =  frequency->data[0][i].re;
                   p[i].im =  frequency->data[0][i].im;
               } else {
                   p[i].re =  frequency->data[0][i].re;
                   p[i].im =  frequency->data[0][i].im;
               }
           }

           output_frame(c_audio, proc_buffer, p, head, window);
        }
    }
}

void decouple(chanend c_in, chanend c_out){
    unsafe {
        int * unsafe p_head;
        int * unsafe p_tail = 0;
        c_in :> p_head;
        unsigned head = 0;
        while(1){
           select {
               case (p_tail == 0) => c_in :> p_tail:{
                   break;
               }
               default:break;
           }
           if(p_head){

               c_out <: p_head[head]*2;
               c_out <: p_head[head]*2;

              xscope_int(0, p_head[head]);

               head++;
               if(head == FFT_N/2){
                   head = 0;
                   p_head = p_tail;
                   p_tail = 0;
               }
           } else {
               c_out <: 0;
               c_out <: 0;
               head = 0;
               p_head = p_tail;
               p_tail = 0;
           }
        }
    }
}


#define OUTPUT_SAMPLE_RATE (96000/DF)
#define MASTER_CLOCK_FREQUENCY 24576000

[[distributable]]
void i2s_handler(server i2s_callback_if i2s,
                 client i2c_master_if i2c, chanend c_audio)
{

  p_rst_shared <: 0xF;

  i2c_regop_res_t res;
  int i = 0x4A;
  uint8_t data = i2c.read_reg(i, 1, res);

  data = i2c.read_reg(i, 0x02, res);
  data |= 1;
  res = i2c.write_reg(i, 0x02, data); // Power down

  // Setting MCLKDIV2 high if using 24.576MHz.
  data = i2c.read_reg(i, 0x03, res);
  data |= 1;
  res = i2c.write_reg(i, 0x03, data);

  data = 0b01110000;
  res = i2c.write_reg(i, 0x10, data);

  data = i2c.read_reg(i, 0x02, res);
  data &= ~1;
  res = i2c.write_reg(i, 0x02, data); // Power up

#define CS2100_I2C_DEVICE_ADDR      (0x9c>>1)
  res = i2c.write_reg(CS2100_I2C_DEVICE_ADDR, 0x3, 0); // Reset the PLL to use the aux out

  while (1) {
    select {

    case i2s.init(i2s_config_t &?i2s_config, tdm_config_t &?tdm_config):
      /* Configure the I2S bus */
      i2s_config.mode = I2S_MODE_LEFT_JUSTIFIED;
      i2s_config.mclk_bclk_ratio = (MASTER_CLOCK_FREQUENCY/OUTPUT_SAMPLE_RATE)/64;

      break;

    case i2s.restart_check() -> i2s_restart_t restart:
      // This application never restarts the I2S bus
      restart = I2S_NO_RESTART;
      break;

    case i2s.receive(size_t index, int32_t sample):
      break;

    case i2s.send(size_t index) -> int32_t sample:
      c_audio:> sample;
      sample <<=3;
      break;
    }
  }
}

int main(){

    i2s_callback_if i_i2s;
    i2c_master_if i_i2c[1];
    chan c_audio, c_decoupled;
    par{

        on tile[1]: {
          configure_clock_src(mclk, p_mclk_in1);
          start_clock(mclk);
          i2s_master(i_i2s, p_i2s_dout, 1, null, 0, p_bclk, p_lrclk, bclk, mclk);
        }

        on tile[1]:  [[distribute]]i2c_master_single_port(i_i2c, 1, p_i2c, 100, 0, 1, 0);
        on tile[1]:  [[distribute]]i2s_handler(i_i2s, i_i2c[0], c_decoupled);

        on tile[0]: {
            streaming chan c_4x_pdm_mic_0, c_4x_pdm_mic_1;
            streaming chan c_ds_output[2];

            interface led_button_if lb[1];

            configure_clock_src_divide(pdmclk, p_mclk, 4);
            configure_port_clock_output(p_pdm_clk, pdmclk);
            configure_in_port(p_pdm_mics, pdmclk);
            start_clock(pdmclk);

            par{
                decouple(c_audio, c_decoupled);
                button_and_led_server(lb, 1, leds, p_buttons);
                pdm_rx(p_pdm_mics, c_4x_pdm_mic_0, c_4x_pdm_mic_1);
                decimate_to_pcm_4ch(c_4x_pdm_mic_0, c_ds_output[0]);
                decimate_to_pcm_4ch(c_4x_pdm_mic_1, c_ds_output[1]);
                noise_red(c_ds_output, lb[0], c_audio);
            }
        }
    }
    return 0;
}

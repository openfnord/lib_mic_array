#pragma once

#include <stdint.h>

/**
 * Number of words of stack for callees of the ISR and of proc_pcm().
 */
#ifndef MA_PDM_RX_STACK_WORDS
# define MA_PDM_RX_STACK_WORDS  100 // TODO: Assert during initialization that this is at least as large as 
                                    //       proc_pcm.nstackwords
#endif // MA_PDM_RX_STACK_WORDS


#ifdef __XC__
extern "C" {
#endif //__XC__



/**
 * This struct maps out the data used by the mic array code.
 * 
 * During initialization, the kernel stack pointer on the core running the mic array
 * is set to the base address of an instance of this struct (i.e.  `&saved_context.sp`),
 * so that each field is at a fixed word offset relative to the kernel stack pointer.
 * 
 * This struct is intended to be embedded within a larger struct (see `ma_pdm_rx_context_t`)
 * which also includes stack space for callees of the mic array ISR.
 */
typedef struct {

  /** Saved thread context from interrupted user thread */
  struct {
    unsigned sp; // <---- The kernel stack pointer gets set to the address of this
    unsigned spc;
    unsigned ssr;
    unsigned sed;
    unsigned et;
    unsigned dp;
    unsigned cp;
    unsigned lr;

    unsigned reg[12];

    unsigned vR[8];
    unsigned vD[8];
    unsigned vC[8];
    unsigned vCTRL;
  } saved_context;

  /**
   * Contains rapidly changing state information needed by the mic array ISR
   */
  struct {
    /** 
     * The ISR trigers multiple times before we have enough PDM samples to produce another PCM sample.
     * This tracks where we are in that sequence. 
     */
    unsigned phase1;

    // This is where raw PDM data (still-channel-interleaved) will go until it's time to decimate. This
    // makes the usual ISR faster, saving MIPS
    unsigned pdm_raw[8];

    /**
     * A second stage of decimation is assumed to occur in proc_pcm(). Rather than call proc_pcm() 
     * for every PCM sample we generate (incurring the cost of a thread context switch each time), 
     * if the second stage has a decimation factor of K, then we need only call proc_pcm() once every
     * K PCM samples, passing a vector in and avoiding most of the context switching cost.
     */
    unsigned phase2;
  } state;

  /**
   * Configuration values for PDM rx
   */
  struct {

    struct {
      /** The number of PDM mics being used. */
      unsigned mic_count;

      /** Resource handle for the PDM mic port */
      unsigned p_pdm_mics;

      /** Pointer to the first stage (PDM->PCM) FIR filter coefficients */
      int16_t* fir_coef;

      /**
       * Pointer to buffers for the PDM sample history.
       */
      uint32_t* pdm_buffer;
    } stage1;

    struct {
      /** The decimation factor used by the second stage in proc_pcm() */
      unsigned decimation_factor;
      
      /**
       * Pointer to buffer for the PCM sample vector.
       */
      int32_t* pcm_vector;
    } stage2;

  } config;

} ma_pdm_rx_static_t;


/**
 * Context in which the mic array ISR (and proc_pcm()) runs. During initialization, the 
 * kernel stack pointer is set to `&workspace`.
 */
typedef struct {
  long long calee_stack[(MA_PDM_RX_STACK_WORDS)/2];
  ma_pdm_rx_static_t workspace;
} ma_pdm_rx_context_t;




typedef struct {

  unsigned mic_count;

  unsigned phase2;

  struct {
    unsigned p_pdm_mics;
    int16_t* fir_coef;
    unsigned* pdm_buffer;
  } stage1;

  struct {
    unsigned decimation_factor;
    int32_t* pcm_vector;
  } stage2;

} pdm_rx_config_t;


void pdm_rx(pdm_rx_config_t* config);


#ifdef __XC__
}
#endif //__XC__
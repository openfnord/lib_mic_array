

#include "mic_array.h"
#include "mic_array/cpp/Prefab.hpp"
#include "app.h"
#include <platform.h>


#if (N_MICS != 2)
pdm_rx_resources_t pdm_res = PDM_RX_RESOURCES_SDR(
                                PORT_MCLK_IN_OUT,
                                PORT_PDM_CLK,
                                PORT_PDM_DATA,
                                MIC_ARRAY_CLK1);
#else
pdm_rx_resources_t pdm_res = PDM_RX_RESOURCES_DDR(
                                PORT_MCLK_IN_OUT,
                                PORT_PDM_CLK,
                                PORT_PDM_DATA,
                                MIC_ARRAY_CLK1,
                                MIC_ARRAY_CLK2);
#endif


using TMicArray = mic_array::prefab::BasicMicArray<
                    N_MICS, SAMPLES_PER_FRAME, DCOE_ENABLED>;

TMicArray mics = TMicArray();

MA_C_API
void app_init()
{
  mics.Init();
  
  // Configure our clocks and ports
  const unsigned mclk_div = mic_array_mclk_divider(
      APP_AUDIO_CLOCK_FREQUENCY, APP_PDM_CLOCK_FREQUENCY);

  mic_array_resources_configure(&pdm_res, mclk_div);

  mics.PdmRx.Init(pdm_res.p_pdm_mics);
}

MA_C_API
void app_pdm_rx_task()
{
  mic_array_pdm_clock_start(&pdm_res);
  mics.PdmRxThreadEntry();
}

MA_C_API
void app_decimator_task(chanend_t c_audio_frames)
{
  mics.SetOutputChannel(c_audio_frames);
  
#if APP_USE_PDM_RX_ISR
  // Start the PDM clock
  mic_array_pdm_clock_start(&pdm_res);

  mics.InstallPdmRxISR();
  mics.UnmaskPdmRxISR();
#endif

  mics.ThreadEntry();
}

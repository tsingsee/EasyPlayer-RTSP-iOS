//
#include "AACDecoder.h"
#include <limits.h>

#define AVCODEC_MAX_AUDIO_FRAME_SIZE	192000

void *aac_decoder_create(enum AVCodecID codecid,    // 解码器ID
                         int sample_rate,           // 采样率(44.1kHZ)
                         int channels,              // 声道数(2)
                         int sample_bits) {         // 采样位数
    AACDFFmpeg *pComponent = (AACDFFmpeg *)calloc(1, sizeof(AACDFFmpeg));
    if (pComponent == NULL) {
        return 0;
    }
    
    // [5]、avcodec_find_decoder()查找解码器
    AVCodec *pCodec = avcodec_find_decoder(codecid);//AV_CODEC_ID_AAC
    if (pCodec == NULL) {
		printf("find %d decoder error", codecid);
        free(pComponent);
        return 0;
    }
    
	printf("aac_decoder_create codecid=%d\r\n", codecid);
    
    pComponent->avCodec = pCodec;
    
    // 创建显示contedxt
    pComponent->pCodecCtx = avcodec_alloc_context3(pCodec);
    if (pComponent->pCodecCtx == NULL) {
        free(pComponent);
        return 0;
    }

    if (channels <= 0 || channels > 2) {
        channels = 1;
    }
    if (sample_rate <= 0) {
        sample_rate = 8000;
    }
    if (sample_bits <= 0) {
        sample_bits = 16;
    }

    pComponent->pCodecCtx->channels = channels;
    pComponent->pCodecCtx->sample_rate = sample_rate;
    pComponent->pCodecCtx->channel_layout = av_get_default_channel_layout(channels);
    
    pComponent->pCodecCtx->bits_per_coded_sample = sample_bits;
    
    printf("bits_per_coded_sample:%d\r\n",pComponent->pCodecCtx->bits_per_coded_sample);
    
    // [6]、如果找到了解码器，则打开解码器
    if(avcodec_open2(pComponent->pCodecCtx, pCodec, NULL) < 0) {
        printf("open codec error\r\n");
        avcodec_free_context(&pComponent->pCodecCtx);
        free(pComponent);
        return 0;
    }
    
    // [7]、打开解码器之后用av_frame_alloc为解码帧分配内存
    pComponent->pFrame = av_frame_alloc();
    if (pComponent->pFrame == NULL) {
        avcodec_close(pComponent->pCodecCtx);
        avcodec_free_context(&pComponent->pCodecCtx);
        free(pComponent);
        return 0;
    }

    pComponent->out_sample_rate = sample_rate;
    pComponent->out_channels = channels;
    pComponent->out_channel_layout = av_get_default_channel_layout(channels);
    pComponent->in_sample_fmt = AV_SAMPLE_FMT_NONE;

    printf("aac_decoder_create end\r\n");
    
    return (void *)pComponent;
}

static int ensure_audio_resampler(AACDFFmpeg *pAACD) {
    int inChannels = pAACD->pFrame->channels > 0 ? pAACD->pFrame->channels : pAACD->pCodecCtx->channels;
    int inSampleRate = pAACD->pFrame->sample_rate > 0 ? pAACD->pFrame->sample_rate : pAACD->pCodecCtx->sample_rate;
    int64_t inChannelLayout = pAACD->pFrame->channel_layout;
    enum AVSampleFormat inSampleFmt = (enum AVSampleFormat)pAACD->pFrame->format;

    if (inChannels <= 0 || inChannels > 8) {
        return -4;
    }
    if (inSampleRate <= 0) {
        return -5;
    }
    if (inChannelLayout == 0) {
        inChannelLayout = pAACD->pCodecCtx->channel_layout;
    }
    if (inChannelLayout == 0) {
        inChannelLayout = av_get_default_channel_layout(inChannels);
    }
    if (inSampleFmt == AV_SAMPLE_FMT_NONE) {
        inSampleFmt = pAACD->pCodecCtx->sample_fmt;
    }
    if (inSampleFmt == AV_SAMPLE_FMT_NONE) {
        return -6;
    }

    if (pAACD->au_convert_ctx != NULL &&
        pAACD->in_sample_rate == inSampleRate &&
        pAACD->in_channels == inChannels &&
        pAACD->in_channel_layout == inChannelLayout &&
        pAACD->in_sample_fmt == inSampleFmt) {
        return 0;
    }

    swr_free(&pAACD->au_convert_ctx);
    pAACD->au_convert_ctx = swr_alloc_set_opts(NULL,
                                              pAACD->out_channel_layout,
                                              AV_SAMPLE_FMT_S16,
                                              pAACD->out_sample_rate,
                                              inChannelLayout,
                                              inSampleFmt,
                                              inSampleRate,
                                              0,
                                              NULL);
    if (pAACD->au_convert_ctx == NULL) {
        return -7;
    }

    int ret = swr_init(pAACD->au_convert_ctx);
    if (ret < 0) {
        swr_free(&pAACD->au_convert_ctx);
        return ret;
    }

    pAACD->in_sample_rate = inSampleRate;
    pAACD->in_channels = inChannels;
    pAACD->in_channel_layout = inChannelLayout;
    pAACD->in_sample_fmt = inSampleFmt;
    return 0;
}

int aac_decode_frame(void *pParam,
                     unsigned char *pData,
                     int nLen,
                     unsigned char *pPCM,
                     unsigned int pcmCapacity,
                     unsigned int *outLen) {
	int pkt_pos = 0;
	int src_len = 0;
	int dst_len = 0;
    
    AACDFFmpeg *pAACD = (AACDFFmpeg *)pParam;
    if (pAACD == NULL || pData == NULL || nLen <= 0 || pPCM == NULL || outLen == NULL || pcmCapacity == 0) {
        return -1;
    }
    *outLen = 0;
    
    AVPacket packet;
    av_init_packet(&packet);
    
    packet.size = nLen;
    packet.data = pData;
    
//    int got_frame = 0;

	while (pkt_pos < nLen) {
        int got_frame = 0;
        
        // 解码
		src_len = avcodec_decode_audio4(pAACD->pCodecCtx, pAACD->pFrame, &got_frame, &packet);
		if (src_len < 0) {
			return -3;
		}
        
		if (got_frame) {
			uint8_t *out[] = {pAACD->audio_buf};
            int ret = ensure_audio_resampler(pAACD);
            if (ret < 0) {
                av_packet_unref(&packet);
                return ret;
            }

            int bytesPerSample = av_get_bytes_per_sample(AV_SAMPLE_FMT_S16);
            if (bytesPerSample <= 0 || pAACD->out_channels <= 0) {
                av_packet_unref(&packet);
                return -8;
            }

            int64_t delay = swr_get_delay(pAACD->au_convert_ctx, pAACD->in_sample_rate);
            int outSamples = (int)av_rescale_rnd(delay + pAACD->pFrame->nb_samples,
                                                pAACD->out_sample_rate,
                                                pAACD->in_sample_rate,
                                                AV_ROUND_UP);
            int maxOutSamples = (int)(sizeof(pAACD->audio_buf) / (pAACD->out_channels * bytesPerSample));
            if (outSamples <= 0) {
                pkt_pos += src_len;
                packet.data = pData + pkt_pos;
                packet.size = nLen - pkt_pos;
                continue;
            }
            if (outSamples > maxOutSamples) {
                av_packet_unref(&packet);
                return -9;
            }

            // swr_convert 的 out_count 单位是 samples，不是字节数。
			int len = swr_convert(pAACD->au_convert_ctx,
                                  out,
                                  outSamples,
                                  (const uint8_t **)pAACD->pFrame->extended_data,
                                  pAACD->pFrame->nb_samples);
			if (len > 0) {
                int convertedSize = av_samples_get_buffer_size(NULL,
                                                              pAACD->out_channels,
                                                              len,
                                                              AV_SAMPLE_FMT_S16,
                                                              1);
                if (convertedSize < 0) {
                    av_packet_unref(&packet);
                    return convertedSize;
                }
                if ((unsigned int)dst_len > pcmCapacity ||
                    (unsigned int)convertedSize > pcmCapacity - (unsigned int)dst_len) {
                    av_packet_unref(&packet);
                    return -10;
                }
				memcpy(pPCM + dst_len, pAACD->audio_buf, convertedSize);
                dst_len += convertedSize;
			} else if (len < 0) {
                av_packet_unref(&packet);
                return len;
			}
		}
        
        if (src_len == 0) {
            break;
        }
		pkt_pos += src_len;
		packet.data = pData + pkt_pos;
		packet.size = nLen - pkt_pos;
	}
    
    if (NULL != outLen)	{
        *outLen = dst_len;
    }
    
//    av_free_packet(&packet);
    av_packet_unref(&packet);
	
    return (dst_len > 0) ? 0 : -1;
}

void aac_decode_close(void *pParam) {
    AACDFFmpeg *pComponent = (AACDFFmpeg *)pParam;
    if (pComponent == NULL) {
        return;
    }
    
    // 关闭重采样
    swr_free(&pComponent->au_convert_ctx);
    
    if (pComponent->pFrame != NULL) {
        // 释放解码后的音频帧数据
        av_frame_free(&pComponent->pFrame);
        pComponent->pFrame = NULL;
    }
    
    if (pComponent->pCodecCtx != NULL) {
        // 释放解码器
        avcodec_close(pComponent->pCodecCtx);
        avcodec_free_context(&pComponent->pCodecCtx);
        pComponent->pCodecCtx = NULL;
    }
    
    free(pComponent);
}

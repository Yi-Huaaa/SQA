#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>
#include <cuda_runtime.h>
#include "cuda_profiler_api.h"
#include <cublas_v2.h>
#include <mma.h>
#include <omp.h>
#include <stdbool.h>
#include <sys/time.h>
#include <cuda_fp16.h>
using namespace nvcuda;
#define IDX2C(i,j,ld) (((j)*(ld))+(i))

// SQA parametersl
#define N 32768
#define M 512
#define M_2 128 // 16 32 64 127 256 512 1024, 7
#define LOG_1(n) (((n) >= 2) ? 1 : 0)
#define LOG_2(n) (((n) >= 1<<2) ? (2 + LOG_1((n)>>2)) : LOG_1(n))
#define LOG_4(n) (((n) >= 1<<4) ? (4 + LOG_2((n)>>4)) : LOG_2(n))
#define LOG_8(n) (((n) >= 1<<8) ? (8 + LOG_4((n)>>8)) : LOG_4(n))
#define LOG(n)   (((n) >= 1<<16) ? (16 + LOG_8((n)>>16)) : LOG_8(n))

#define TIMES 5
#define STEP 100


// Must be multiples of 16
#define MATRIX_M N
#define MATRIX_K M_2
#define MATRIX_N M

// Error check macros
#define cudaErrCheck(stat) { cudaErrCheck_((stat), __FILE__, __LINE__); }
void cudaErrCheck_(cudaError_t stat, const char *file, int line) {
   if (stat != cudaSuccess) {
      fprintf(stderr, "CUDA Error: %s %s %d\n", cudaGetErrorString(stat), file, line);
   }
}

#define cublasErrCheck(stat) { cublasErrCheck_((stat), __FILE__, __LINE__); }
void cublasErrCheck_(cublasStatus_t stat, const char *file, int line) {
   if (stat != CUBLAS_STATUS_SUCCESS) {
      fprintf(stderr, "cuBLAS Error: %d %s %d\n", stat, file, line);
   }
}

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert (cudaError_t code, const char *file, int line, bool abort=true){
   if (code != cudaSuccess){
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}
void usage ();
void check_spin(float *spin, int total_spins);
void check_couplings(float *couplings);
void check_delta_H (float *couplings, float *spin, float *delta_H, float *delta_H_fp32);
void check_matrix_B (float *matrix_B, float *matrix_B_fp32);

void construct_spin(half *spin, half *spin_fp32,int total_spins){
    float x;
    for (int n = 0; n < N; n++){
        for(int m = 0; m < M; m++){
            x = ((float)rand()/(float)(RAND_MAX)) * 1.0;    
            spin[IDX2C(n,m,N)] = ((x>=0.5) ? (float)1. : (float)-1.);
        }
    }
    cudaErrCheck (cudaMemcpy(spin_fp32, spin, M*N*sizeof(half), cudaMemcpyHostToDevice));
}

void construct_rand_val(float *rand_val, float *rand_val_fp32){
    for(int i = 0; i < N; i++){
        for(int j = 0; j < M; j++){
            rand_val[IDX2C(i,j,N)] = ((float)rand()/(float)(RAND_MAX)) * 1.0;
        }
    }
    cudaErrCheck (cudaMemcpy(rand_val_fp32, rand_val, M*N*sizeof(float), cudaMemcpyHostToDevice));
}

void construct_delta_H(cublasHandle_t cublasHandle, half *couplings_fp16, half *spin_fp32, float *delta_H_fp32){
    //int idx = blockIdx.x * blockDim.x + threadIdx.x;
    
    float alpha = 1.0f, beta = 0.0f;
    cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N,
                                N, M, N,
                                &alpha,
                                couplings_fp16, CUDA_R_16F, N,
                                spin_fp32, CUDA_R_16F, N,
                                &beta,
                                delta_H_fp32, CUDA_R_32F, N,
#if (__CUDA_ARCH__  >= 800)
                                CUBLAS_COMPUTE_32F, 
#else
                                CUDA_R_32F,
#endif  
                                CUBLAS_GEMM_DEFAULT_TENSOR_OP));
}

void update_delta_H(cublasHandle_t cublasHandle, half *couplings_fp16, half *matrix_B_fp16, float *delta_H_fp32, int which_spin){
    float alpha = 1.0f, beta = 1.0f;    
    unsigned long long int blk_num = which_spin / M_2;
    int loop_iter = (N/32768 == 0) ? 1 : N/32768; 
    int matrix_m = (N > 32768) ? 32768 : N;

    for (int i = 0; i < loop_iter; i++) {
        unsigned long long int coup_idx = blk_num * (N * M_2) + i*32768*M_2;
        cublasErrCheck(cublasGemmEx(cublasHandle, CUBLAS_OP_N, CUBLAS_OP_N,
                                    matrix_m, MATRIX_N, MATRIX_K,
                                    &alpha,
                                    couplings_fp16 + coup_idx, CUDA_R_16F, matrix_m,
                                    matrix_B_fp16, CUDA_R_16F, MATRIX_K,
                                    &beta,
                                    delta_H_fp32, CUDA_R_32F, matrix_m,
#if (__CUDA_ARCH__  >= 800)
                                    CUBLAS_COMPUTE_32F, 
#else
                                    CUDA_R_32F,
#endif  
                                    CUBLAS_GEMM_DEFAULT_TENSOR_OP));
    }
}

void construct_lograndval(float *log_rand_val, float *log_rand_val_fp32, cudaStream_t stream){
    #pragma omp parallel for num_threads(16)
    for(int i = 0; i < N; i++){
        log_rand_val[IDX2C(i,0,N)] = (-log(((float)rand()/(float)(RAND_MAX))));
    }
    #pragma omp parallel for num_threads(16)
    for (int m = M-1; m >= 1; m--)
        memcpy(&log_rand_val[m*N], &log_rand_val[(m-1)*N], N*sizeof(float));
    cudaErrCheck (cudaMemcpy(log_rand_val_fp32, log_rand_val, M*N*sizeof(float), cudaMemcpyHostToDevice));
}

float calculate_maxcut (half *spin, half *spin_fp32, half *couplings, int total_spins, int total_couplings){
    cudaErrCheck(cudaMemcpy(spin, spin_fp32, M*N*sizeof(half), cudaMemcpyDeviceToHost));
    // check_spin(spin, total_spins);
    float E = 0;
    for (int i = 0; i < total_spins; i++){
        for (int j = i+1; j < total_spins; j++){
            E += -(float)spin[IDX2C(i,0,N)]*(float)spin[IDX2C(j,0,N)]*(float)couplings[IDX2C(i,j,N)];
        }
    }
    // printf("E = %f\n", E);
    // return E;
    float maxCut = 0.;
    for (int i = 0; i < total_spins; i++){
        for (int j = i+1; j < total_spins; j++){
            // printf("spin[IDX2C(%d,N)] = %f,  spin[IDX2C(%d,N)]) = %f\n",i, spin[IDX2C(i,0,N)], j,spin[IDX2C(j,0,N)] );

            //maxCut += ((1.0 - spin[IDX2C(i,0,N)]*spin[IDX2C(j,0,N)])/2)*((float)couplings[IDX2C(i,j,N)]);
            if(((float)spin[IDX2C(i,0,N)] != (float)spin[IDX2C(j,0,N)])){
                // printf("(float)couplings[IDX2C(%d,%d,N)] = %f, spin[IDX2C(%d,N)] = %f,  spin[IDX2C(%d,N)]) = %f\n", i, j, (float)couplings[IDX2C(i,j,N)], i, spin[IDX2C(i,0,N)], j,spin[IDX2C(j,0,N)] );
                maxCut += (float)couplings[IDX2C(i,j,N)];
            }
        }
    }
    // int pos = 0, neg = 0;
    // for (int i = 0; i < total_spins; i++){
    //     if(spin[IDX2C(i,0,N)] == 1)
    //         pos ++;
    //     else 
    //         neg ++;
    // }
    // printf("pos = %d, neg = %d, total = %d\n", pos, neg, (pos + neg));
    // if(maxCut < 0){
    //     maxCut *= -1;
    // }
    return -(maxCut);
}



__global__ void judge_flipping_com (half *couplings_fp16, float *delta_H_fp32, half *spin_fp32, half *matrix_B_fp16, float *log_rand_val_fp32, int J_perp, float beta, int start_spin){
    int m = blockIdx.x;
    int idx, mb_idx, upper, lower;
    float delta;
    int first_rd_idx = m&1; //even:0, odd:1
    
    int s_idx = start_spin+threadIdx.x+(m<<LOG(N));
    extern __shared__ float deltas[M_2];
    deltas[threadIdx.x] = delta_H_fp32[s_idx];
    extern __shared__ float l_log_rand_val_fp32[M_2];
    l_log_rand_val_fp32[threadIdx.x] = log_rand_val_fp32[s_idx];
    __syncthreads();
    
    upper = (m-1) & (M-1);
    lower = (m+1) & (M-1);
        
    // even: 0~M_2/2-1; odd: M_2/2~M_2-1
    #pragma unroll
    for (int n = 0; n < M_2; n++) {
        int lidx = (first_rd_idx*(M_2/2) + n)&(M_2-1);
        int nn = start_spin + lidx;
        idx = (nn+(m<<LOG(N)));
        mb_idx = (lidx+(m<<LOG(M_2)));            
        delta = deltas[lidx];
        delta = beta*(float)spin_fp32[idx]*(delta - J_perp*((float)spin_fp32[(nn+(upper<<LOG(N)))] 
                                            + (float)spin_fp32[(nn+(lower<<LOG(N)))]));
        
        matrix_B_fp16[mb_idx] = 0;
        if ( (l_log_rand_val_fp32[lidx]) > delta ) {
            spin_fp32[idx] = -spin_fp32[idx];
            // matrix_B_fp16[mb_idx] = 2*spin_fp32[idx];
            matrix_B_fp16[mb_idx] = (spin_fp32[idx]+spin_fp32[idx]);
            int ii = start_spin + threadIdx.x;
            deltas[threadIdx.x] += (float)couplings_fp16[(ii+(nn<<LOG(N)))]*(float)matrix_B_fp16[mb_idx]; 
        } 
        __syncthreads();
    }
}

__global__ void warm_up_gpu(){
    unsigned int tid = blockIdx.x * blockDim.x + threadIdx.x;
    float ia, ib;
    ia = ib = 0.0f;
    ib += ia + tid; 
}

int main(int argc, char* argv[]) {
    if (argc != 2) 
        usage();
    
    //Initialize TC, for check
    cublasHandle_t cublasHandle;
    cudaEvent_t startcublas;
    cudaEvent_t stopcublas;

    cudaErrCheck(cudaEventCreate(&startcublas));
    cudaErrCheck(cudaEventCreate(&stopcublas));
    cublasErrCheck(cublasCreate(&cublasHandle));
    
    // Initialize couplings
    half *couplings; // cpu    
    couplings = (half*)malloc(N * N * sizeof(half));
    memset(couplings, 0, N*N*sizeof(half));
    
    half *couplings_fp16; 
    cudaErrCheck(cudaMalloc((void**)&couplings_fp16, N*N*sizeof(half)));
    
    // Read files
    FILE *instance = fopen(argv[1], "r");
    assert(instance != NULL);
    int a, b, total_spins, total_couplings;
    float w;
    fscanf(instance, "%d%d", &total_spins, &total_couplings);
    while (total_couplings --) {
        fscanf(instance, "%d%d%f", &a, &b, &w);
        a--;
        b--;
        couplings[IDX2C(a,b,N)] = -w;
        couplings[IDX2C(b,a,N)] = -w;
    }
    fclose(instance);

    // copy couplings to target device
    cudaErrCheck ( cudaMemcpy(couplings_fp16, couplings, N*N*sizeof(half), cudaMemcpyHostToDevice) );
    
    // Initialize spin
    half *spin;
    spin = (half*)malloc(M*N*sizeof(half));
    memset(spin, 0, M*N*sizeof(half)); // must initialize, since there are some places not 0
    
    half *spin_fp32;
    cudaErrCheck ( cudaMalloc((void**)&spin_fp32, M*N*sizeof(half)) );
    cudaErrCheck(cudaMemcpy(spin_fp32, spin, M*N*sizeof(half), cudaMemcpyHostToDevice));

    float *delta_H;
    delta_H = (float*)malloc(M*N*sizeof(float));
    memset(delta_H, 0, M*N*sizeof(float));
    
    float *delta_H_fp32;
    cudaErrCheck(cudaMalloc((void**)&delta_H_fp32, M*N*sizeof(float)));
    cudaErrCheck(cudaMemcpy(delta_H_fp32, delta_H, M*N*sizeof(float), cudaMemcpyHostToDevice));

    half *matrix_B_fp16;
    cudaErrCheck(cudaMalloc((void**)&matrix_B_fp16, M*M_2*sizeof(half)));
    
    float *log_rand_val;
    cudaErrCheck(cudaMallocHost((void**)&log_rand_val, M*N*sizeof(float)));
    //log_rand_val = (float*)malloc(M*N*sizeof(float));
    
    float *log_rand_val_fp32;
    cudaErrCheck(cudaMalloc((void**)&log_rand_val_fp32, M*N*sizeof(float)));
    
    // TC, using tensor core
    cublasErrCheck(cublasSetMathMode(cublasHandle, CUBLAS_TENSOR_OP_MATH));  //CUBLAS_PEDANTIC_MATH, CUBLAS_TENSOR_OP_MATH
    
    // Parameters init
    float results[TIMES] = {0.};
    float used_time[TIMES] = {0.};
    //float increase = (16. - 1/(float)16) / (float)STEP;
    float increase = (1. - 1/(float)16) / (float)STEP;
    float G0 = 8.;

    cudaStream_t stream1, stream2;
    cudaErrCheck(cudaStreamCreateWithFlags(&stream1, cudaStreamNonBlocking));
    cudaErrCheck(cudaStreamCreateWithFlags(&stream2, cudaStreamNonBlocking));
    cublasErrCheck(cublasSetStream(cublasHandle, stream2));
    
    float *best_spin;
    best_spin = (float*)malloc(M*N*sizeof(float));
    memset(best_spin, 0, M*N*sizeof(float)); 
    float best_E = 1e9;
    float best_cut = -1e9;
    
    warm_up_gpu <<< M, M_2 >>> ();

    for (int t = 0; t < TIMES; t++) {
        float beta = 1/(float)16; //bete = 1/Time
        
        //init spin
        construct_spin(spin, spin_fp32, total_spins);
        construct_delta_H(cublasHandle, couplings_fp16, spin_fp32, delta_H_fp32);
        cudaDeviceSynchronize();

        // Current cost time
        struct timeval begin, end;
        gettimeofday(&begin, NULL);

        for (int p = 0; p < STEP; p++) {
            
            float Gamma = G0*(1.-(float)p/(float)STEP);
            float J_perp = -M*0.5*log(tanh((Gamma/M)*beta))/beta;
            
            construct_lograndval(log_rand_val, log_rand_val_fp32, stream1);
            for (int n = 0; n < N; n += M_2) {
                judge_flipping_com <<< M, M_2, 2*M_2*sizeof(float), stream2 >>> (couplings_fp16, delta_H_fp32, 
                    spin_fp32, matrix_B_fp16, log_rand_val_fp32, J_perp, 2*M*beta, n);
                update_delta_H(cublasHandle, couplings_fp16, matrix_B_fp16, delta_H_fp32, n);              
            }
            beta += increase;
            // best_E = calculate_maxcut(spin, spin_fp32, couplings, total_spins, total_couplings);
            // if(best_E > best_cut)
            //     best_cut = best_E;
        } 
        cudaDeviceSynchronize();
        gettimeofday(&end, NULL);
        double duration = ((end.tv_sec  - begin.tv_sec) * 1000000u +
                         end.tv_usec - begin.tv_usec) / 1.e6;
            
        used_time[t] = duration;
        
        best_E = calculate_maxcut(spin, spin_fp32, couplings, total_spins, total_couplings);
        //memcpy(best_spin, spin, M*N*sizeof(float));
        results[t] = best_E;
        if(best_E > best_cut)
            best_cut = best_E;
    }
    
    for (int t = 0; t < TIMES; t++){
        printf("TIME: %d,  used time (s): %10lf,  Maxcut: %10lf\n", t, used_time[t], results[t]);
    }
    float tot_result_time = 0., tot_energy = 0.;
    for(int i = 0; i < TIMES; i++){
        tot_result_time += used_time[i];
        tot_energy += results[i];

    }
    printf("\nAvg time  : %f\n", tot_result_time/TIMES);
    printf("Avg Maxcut: %f, Best cut = %f\n", tot_energy/TIMES, best_cut);

    cublasDestroy(cublasHandle); 
    cudaStreamDestroy(stream1);
    cudaStreamDestroy(stream2);
    free(couplings);
    free(spin);
    free(delta_H);
    cudaFreeHost(log_rand_val);
    cudaFree(couplings_fp16);
    cudaFree(spin_fp32);
    cudaFree(delta_H_fp32);
    cudaFree(matrix_B_fp16);
    cudaFree(log_rand_val_fp32);
    
    return 0;
}

void usage (){
    printf("Usage:\n");
    printf("       ./sqa [spin configuration]\n");
    exit(0);
}

void check_spin(float *spin, int total_spins){
    printf("\ncheck_spin:\n");
    for (int n = 0; n < total_spins; n++){
        for(int m = 0; m < M; m++){
            printf("%d ", (int)spin[IDX2C(n,m,N)] );
        }
        printf("\n");
    }
}

void check_couplings(float *couplings){
    printf("\ncheck_couplings:\n");
    for (int n = 0; n < N; n++){
        for(int k = 0; k < N; k++){
            printf("%d ", (int)couplings[IDX2C(n,k,N)] );
        }
        printf("\n");
    }
}

void check_delta_H (float *couplings, float *spin, float *delta_H, float *delta_H_fp32){
    cudaErrCheck ( cudaMemcpy(delta_H, delta_H_fp32, M*N*sizeof(float), cudaMemcpyDeviceToHost));
    printf("check..., print delta_H\n");
    for (int n = 0; n < N; n++){
        for (int m = 0; m < M; m++){
            printf("%d ", (int)delta_H[IDX2C(n,m,N)]);
        }
        printf("\n");
    }
}

void check_matrix_B (float *matrix_B, float *matrix_B_fp32){
    cudaErrCheck(cudaMemcpy(matrix_B, matrix_B_fp32, M*N*sizeof(float), cudaMemcpyDeviceToHost));
    printf("check..., matrix_B:\n");
    for (int n = 0; n < N; n++){
        for (int m = 0; m < M; m++){
            printf("%d ", (int)matrix_B[IDX2C(n,m,N)]);
        }
        printf("\n");
    }
}

/*
 *
 * testScanBlock.cu
 *
 * Microdemo to test block scan algorithms.  These are built on top of
 * the warp scan algorithms in the warp directory.
 *
 * Build with: nvcc -I ..\chLib <options> testScanBlock.cu
 * Requires: No minimum SM requirement.
 *
 * Copyright (c) 2011-2012, Archaea Software, LLC.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions 
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright 
 *    notice, this list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright 
 *    notice, this list of conditions and the following disclaimer in 
 *    the documentation and/or other materials provided with the 
 *    distribution. 
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS 
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
 * COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 * INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
 * POSSIBILITY OF SUCH DAMAGE.
 *
 */

#include <stdlib.h>

#include <thrust/host_vector.h>
#include <thrust/device_vector.h>

#include <chAssert.h>
#include <chError.h>

#include "scanWarp.cuh"
#include "scanWarp2.cuh"
#include "scanWarpShuffle.cuh"

#include "scanBlock.cuh"
//#include "scanBlockShuffle.cuh"

#include "scanZeroPad.cuh"


#define min(a,b) ((a)<(b)?(a):(b))

enum ScanType {
    Inclusive, Exclusive
};

template<int period>
void
ScanExclusiveCPUPeriodic( int *out, const int *in, size_t N )
{
    for ( size_t i = 0; i < N; i += period ) {
        int sum = 0;
        for ( size_t j = 0; j < period; j++ ) {
            int next = in[i+j]; // in case we are doing this in place
            out[i+j] = sum;
            sum += next;
        }
    }
}

template<int period>
void
ScanInclusiveCPUPeriodic( int *out, const int *in, size_t N )
{
    for ( size_t i = 0; i < N; i += period ) {
        int sum = 0;
        for ( size_t j = 0; j < period; j++ ) {
            sum += in[i+j];
            out[i+j] = sum;
        }
    }
}

template<ScanType scantype>
void
ScanCPU32( int *out, const int *in, size_t N )
{
    switch ( scantype ) {
        case Exclusive: return ScanExclusiveCPUPeriodic<32>( out, in, N );
        case Inclusive: return ScanInclusiveCPUPeriodic<32>( out, in, N );
    }
}

template<ScanType scantype>
void
ScanCPUBlock( int *out, const int *in, size_t N, int numThreads )
{
    switch ( numThreads ) {
        case 256:
            switch ( scantype ) {
                case Exclusive: return ScanExclusiveCPUPeriodic<256>( out, in, N );
                case Inclusive: return ScanInclusiveCPUPeriodic<256>( out, in, N );
            }
        case 512:
            switch ( scantype ) {
                case Exclusive: return ScanExclusiveCPUPeriodic<512>( out, in, N );
                case Inclusive: return ScanInclusiveCPUPeriodic<512>( out, in, N );
            }
        case 1024:
            switch ( scantype ) {
                case Exclusive: return ScanExclusiveCPUPeriodic<1024>( out, in, N );
                case Inclusive: return ScanInclusiveCPUPeriodic<1024>( out, in, N );
            }
        default: return;
    }
}

void
RandomArray( int *out, size_t N, int modulus )
{
    for ( size_t i = 0; i < N; i++ ) {
        out[i] = rand() % modulus;
    }
}

template<ScanType scantype>
__global__ void
ScanGPUWarp( int *out, const int *in, size_t N )
{
    extern __shared__ int sPartials[];
    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        sPartials[threadIdx.x] = in[i+threadIdx.x];
        __syncthreads();
        if ( scantype == Inclusive ) {
            out[i+threadIdx.x] = scanWarp<int,false>( sPartials+threadIdx.x );
        }
        else {
            out[i+threadIdx.x] = scanWarpExclusive<int,false>( sPartials+threadIdx.x );
        }
    }
}

template<ScanType scantype>
void
ScanGPU( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanGPUWarp<scantype><<<cBlocks, cThreads, cThreads*sizeof(int)>>>( 
        out, in, N );
}

template<ScanType scantype>
__global__ void
ScanGPUBlock( int *out, const int *in, size_t N )
{
    extern __shared__ int sPartials[];
    const int tid = threadIdx.x;
    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        sPartials[tid] = in[i+tid];
        __syncthreads();
        int myValue = scanBlock<int,false>( sPartials+tid, scanWarp<int,false> );
        if ( scantype==Exclusive) {
            __syncthreads();
            myValue = (tid) ? sPartials[tid-1] : 0;
        }
        out[i+threadIdx.x] = myValue;
    }
}

template<ScanType scantype>
void
ScanGPUBlock( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanGPUBlock<scantype><<<cBlocks, cThreads, cThreads*sizeof(int)>>>( 
        out, in, N );
}

template<ScanType scantype, int logBlockSize>
__global__ void
ScanGPUBlockShuffle( int *out, const int *in, size_t N )
{
    const int tid = threadIdx.x;
    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        int myValue = in[i+tid];
        if ( scantype == Exclusive ) {
            myValue = exclusive_scan_block<logBlockSize>( myValue, tid );
        }
        else {
            myValue = inclusive_scan_block<logBlockSize>( myValue, tid );
        }
        out[i+threadIdx.x] = myValue;
    }
}

template<ScanType scantype>
void
ScanGPUBlockShuffle( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    /*if ( scantype == Inclusive )*/ {
        switch( cThreads ) {
            case  128: return ScanGPUBlockShuffle<scantype, 7><<<cBlocks,cThreads>>>( out, in, N );
            case  256: return ScanGPUBlockShuffle<scantype, 8><<<cBlocks,cThreads>>>( out, in, N );
            case  512: return ScanGPUBlockShuffle<scantype, 9><<<cBlocks,cThreads>>>( out, in, N );
            case 1024: return ScanGPUBlockShuffle<scantype,10><<<cBlocks,cThreads>>>( out, in, N );
        }
#if 0
        ScanGPUBlockShuffle<scantype><<<cBlocks, cThreads>>>( 
            out, in, N );
#endif
    }
    ScanGPUBlock<scantype><<<cBlocks, cThreads, cThreads*sizeof(int)>>>( 
        out, in, N );
}

__global__ void
ScanInclusiveGPUWarp_0( int *out, const int *in, size_t N )
{
    extern __shared__ int sPartials[];
    const int sIndex = scanSharedIndex<true>( threadIdx.x );

    sPartials[sIndex-16] = 0;

    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        sPartials[sIndex] = in[i+threadIdx.x];
        out[i+threadIdx.x] = scanWarp<int,true>( sPartials+sIndex );
    }
}

void
ScanInclusiveGPU_0( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanInclusiveGPUWarp_0<<<cBlocks, 
        cThreads, 
        scanSharedMemory<int,true>(cThreads)>>>( 
        out, in, N );
}

__global__ void
ScanExclusiveGPUWarp_0( int *out, const int *in, size_t N )
{
    extern __shared__ int sPartials[];
    const int sIndex = scanSharedIndex<true>( threadIdx.x );

    sPartials[sIndex-16] = 0;

    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        sPartials[sIndex] = in[i+threadIdx.x];
        out[i+threadIdx.x] = scanWarpExclusive<int,true>( sPartials+sIndex );
    }
}

void
ScanExclusiveGPU_0( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanExclusiveGPUWarp_0<<<cBlocks, 
        cThreads, 
        scanSharedMemory<int,true>(cThreads)>>>( 
        out, in, N );
}

__global__ void
ScanInclusiveGPUWarp2( int *out, const int *in, size_t N )
{
    extern __shared__ int sPartials[];
    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        sPartials[threadIdx.x] = in[i+threadIdx.x];
        __syncthreads();
        out[i+threadIdx.x] = scanWarp2<int,false>( sPartials+threadIdx.x );
    }
}

void
ScanInclusiveGPU2( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanInclusiveGPUWarp2<<<cBlocks, cThreads, cThreads*sizeof(int)>>>( 
            out, in, N );
}

__global__ void
ScanExclusiveGPUWarp2( int *out, const int *in, size_t N )
{
    extern __shared__ int sPartials[];
    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        sPartials[threadIdx.x] = in[i+threadIdx.x];
        __syncthreads();
        out[i+threadIdx.x] = scanWarpExclusive2<int,false>( sPartials+threadIdx.x );
    }
}

void
ScanExclusiveGPU2( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanExclusiveGPUWarp2<<<cBlocks, cThreads, cThreads*sizeof(int)>>>( 
            out, in, N );
}

template<ScanType scantype>
__global__ void
ScanGPUWarpShuffle( int *out, const int *in, size_t N )
{
    for ( size_t i = blockIdx.x*blockDim.x;
                 i < N;
                 i += blockDim.x ) {
        if ( scantype == Inclusive ) {
            out[i+threadIdx.x] = inclusive_scan_warp_shfl<5>( in[i+threadIdx.x] );
        }
        else {
            out[i+threadIdx.x] = exclusive_scan_warp_shfl<5>( in[i+threadIdx.x] );
        }
    }
}

template<ScanType scantype>
void
ScanGPUShuffle( 
    int *out, 
    const int *in, 
    size_t N, 
    int cThreads )
{
    int cBlocks = (int) (N/150);
    if ( cBlocks > 150 ) {
        cBlocks = 150;
    }
    ScanGPUWarpShuffle<scantype><<<cBlocks, cThreads>>>( out, in, N );
}

template<class T>
bool
TestScanBlock( 
    float *pMelementspersecond,
    const char *szScanFunction, 
    void (*pfnScanCPU)(T *, const T *, size_t, int),
    void (*pfnScanGPU)(T *, const T *, size_t, int), 
    size_t N, 
    int numThreads )
{
    bool ret = false;
    cudaError_t status;
    int *inGPU = 0;
    int *outGPU = 0;
    int *inCPU = (T *) malloc( N*sizeof(T) );
    int *outCPU = (int *) malloc( N*sizeof(T) );
    int *hostGPU = (int *) malloc( N*sizeof(T) );
    cudaEvent_t evStart = 0, evStop = 0;
    if ( 0==inCPU || 0==outCPU || 0==hostGPU )
        goto Error;

    printf( "Testing %s (%d threads/block)\n", szScanFunction, numThreads );

    CUDART_CHECK( cudaEventCreate( &evStart ) );
    CUDART_CHECK( cudaEventCreate( &evStop ) );
    CUDART_CHECK( cudaMalloc( &inGPU, N*sizeof(T) ) );
    CUDART_CHECK( cudaMalloc( &outGPU, N*sizeof(T) ) );
    CUDART_CHECK( cudaMemset( inGPU, 0, N*sizeof(T) ) );
    CUDART_CHECK( cudaMemset( outGPU, 0, N*sizeof(T) ) );

    CUDART_CHECK( cudaMemset( outGPU, 0, N*sizeof(T) ) );

    RandomArray( inCPU, N, 256 );
for ( int i = 0; i < N; i++ ) {
    inCPU[i] = i;
}
    
    pfnScanCPU( outCPU, inCPU, N, numThreads );

    CUDART_CHECK( cudaMemcpy( inGPU, inCPU, N*sizeof(T), cudaMemcpyHostToDevice ) );
    CUDART_CHECK( cudaEventRecord( evStart, 0 ) );
    pfnScanGPU( outGPU, inGPU, N, numThreads );
    CUDART_CHECK( cudaEventRecord( evStop, 0 ) );
    CUDART_CHECK( cudaMemcpy( hostGPU, outGPU, N*sizeof(T), cudaMemcpyDeviceToHost ) );
    for ( size_t i = 0; i < N; i++ ) {
        if ( hostGPU[i] != outCPU[i] ) {
            printf( "Scan failed\n" );
#ifdef _WIN32
            __debugbreak();//_asm int 3
#else
            assert(0);
#endif
            goto Error;
        }
    }
    {
        float ms;
        CUDART_CHECK( cudaEventElapsedTime( &ms, evStart, evStop ) );
        double Melements = N/1e6;
        *pMelementspersecond = 1000.0f*Melements/ms;
    }
    ret = true;
Error:
    cudaEventDestroy( evStart );
    cudaEventDestroy( evStop );
    cudaFree( outGPU );
    cudaFree( inGPU );
    free( inCPU );
    free( outCPU );
    free( hostGPU );
    return ret;
}

int
main( int argc, char *argv[] )
{
    cudaError_t status;
    int maxThreads;
    int numInts = 32*1048576;

    CUDART_CHECK( cudaSetDevice( 0 ) );
    CUDART_CHECK( cudaSetDeviceFlags( cudaDeviceMapHost ) );

    {
        cudaDeviceProp prop;
        cudaGetDeviceProperties( &prop, 0 );
        maxThreads = prop.maxThreadsPerBlock;
    }

#define SCAN_TEST_VECTOR( CPUFunction, GPUFunction, N, numThreads ) do { \
    float fMelementsPerSecond; \
    srand(0); \
    bool bSuccess = TestScanBlock<int>( &fMelementsPerSecond, #GPUFunction, CPUFunction, GPUFunction, N, numThreads ); \
    if ( ! bSuccess ) { \
        printf( "%s failed: N=%d, numThreads=%d\n", #GPUFunction, N, numThreads ); \
        exit(1); \
    } \
    if ( fMelementsPerSecond > maxElementsPerSecond ) { \
        maxElementsPerSecond = fMelementsPerSecond; \
    } \
\
} while (0)

    printf( "Problem size: %d integers\n", numInts );

    for ( int numThreads = 256; numThreads <= maxThreads; numThreads *= 2 ) {
        float maxElementsPerSecond = 0.0f;
#if 0
        SCAN_TEST_VECTOR( ScanCPUBlock<Exclusive>, ScanGPUBlock<Exclusive>, numInts, numThreads );
        printf( "GPU: %.2f Melements/s\n", maxElementsPerSecond );
        maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPUBlock<Exclusive>, ScanExclusiveGPU_0, numInts, numThreads );
        printf( "GPU: %.2f Melements/s\n", maxElementsPerSecond );
        maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPUBlock<Exclusive>, ScanExclusiveGPU2, numInts, numThreads );
        printf( "GPU2: %.2f Melements/s\n", maxElementsPerSecond );
#endif
        maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPUBlock<Exclusive>, ScanGPUBlockShuffle<Exclusive>, numInts, numThreads );
        printf( "Shuffle: %.2f Melements/s\n", maxElementsPerSecond );
    }

    for ( int numThreads = 256; numThreads <= maxThreads; numThreads *= 2 ) {
        float maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPUBlock<Inclusive>, ScanGPUBlock<Inclusive>, numInts, numThreads );
        printf( "GPU: %.2f Melements/s\n", maxElementsPerSecond );
#if 0
        maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPU32<Inclusive>, ScanInclusiveGPU_0, numInts, numThreads );
        printf( "GPU: %.2f Melements/s\n", maxElementsPerSecond );
        maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPU32<Inclusive>, ScanInclusiveGPU2, numInts, numThreads );
        printf( "GPU2: %.2f Melements/s\n", maxElementsPerSecond );
#endif
        maxElementsPerSecond = 0.0f;
        SCAN_TEST_VECTOR( ScanCPUBlock<Inclusive>, ScanGPUBlockShuffle<Inclusive>, numInts, numThreads );
        printf( "Shuffle: %.2f Melements/s\n", maxElementsPerSecond );
    }

    return 0;
Error:
    return 1;
}

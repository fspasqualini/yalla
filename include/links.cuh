// Links between points, to simulate protrusions, ... Similar models have been
// used in https://dx.doi.org/doi:10.1073/pnas.97.19.10448 and
// https://dx.doi.org/doi:10.1371/journal.pcbi.1004952
#pragma once

#include <assert.h>
#include <curand_kernel.h>
#include <time.h>
#include <functional>

#include "utils.cuh"


struct Link {
    int a, b;
};

using Check_link = std::function<bool(int a, int b)>;

bool every_link(int a, int b) { return true; }

class Links {
public:
    Link* h_link;
    Link* d_link;
    int* h_n = (int*)malloc(sizeof(int));
    int* d_n;
    const int n_max;
    curandState* d_state;
    float strength;
    Links(int n_max, float strength = 1.f / 5)
        : n_max{n_max}, strength{strength}
    {
        h_link = (Link*)malloc(n_max * sizeof(Link));
        cudaMalloc(&d_link, n_max * sizeof(Link));
        cudaMalloc(&d_n, sizeof(int));
        cudaMalloc(&d_state, n_max * sizeof(curandState));
        *h_n = n_max;
        set_d_n(n_max);
        reset();
        auto seed = time(NULL);
        setup_rand_states<<<(n_max + 32 - 1) / 32, 32>>>(n_max, seed, d_state);
    }
    ~Links()
    {
        free(h_n);
        free(h_link);
        cudaFree(d_link);
        cudaFree(d_n);
        cudaFree(d_state);
    }
    void set_d_n(int n)
    {
        assert(n <= n_max);
        cudaMemcpy(d_n, &n, sizeof(int), cudaMemcpyHostToDevice);
    }
    int get_d_n()
    {
        int n;
        cudaMemcpy(&n, d_n, sizeof(int), cudaMemcpyDeviceToHost);
        assert(n <= n_max);
        return n;
    }
    void reset(Check_link check = every_link)
    {
        copy_to_host();
        for (auto i = 0; i < n_max; i++) {
            if (!check(h_link[i].a, h_link[i].b)) continue;

            h_link[i].a = 0;
            h_link[i].b = 0;
        }
        copy_to_device();
    }
    void copy_to_device()
    {
        assert(*h_n <= n_max);
        cudaMemcpy(
            d_link, h_link, n_max * sizeof(Link), cudaMemcpyHostToDevice);
        cudaMemcpy(d_n, h_n, sizeof(int), cudaMemcpyHostToDevice);
    }
    void copy_to_host()
    {
        cudaMemcpy(
            h_link, d_link, n_max * sizeof(Link), cudaMemcpyDeviceToHost);
        cudaMemcpy(h_n, d_n, sizeof(int), cudaMemcpyDeviceToHost);
        assert(*h_n <= n_max);
    }
};


template<typename Pt>
using Link_force = void(const Pt* __restrict__ d_X, const int a, const int b,
    const float strength, Pt* d_dX);

template<typename Pt>
__device__ void linear_force(const Pt* __restrict__ d_X, const int a,
    const int b, const float strength, Pt* d_dX)
{
    auto r = d_X[a] - d_X[b];
    auto dist = norm3df(r.x, r.y, r.z);

    atomicAdd(&d_dX[a].x, -strength * r.x / dist);
    atomicAdd(&d_dX[a].y, -strength * r.y / dist);
    atomicAdd(&d_dX[a].z, -strength * r.z / dist);
    atomicAdd(&d_dX[b].x, strength * r.x / dist);
    atomicAdd(&d_dX[b].y, strength * r.y / dist);
    atomicAdd(&d_dX[b].z, strength * r.z / dist);
}

template<typename Pt, Link_force<Pt> force>
__global__ void link(const Pt* __restrict__ d_X, Pt* d_dX,
    const Link* __restrict__ d_link, int n_max, float strength)
{
    auto i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n_max) return;

    auto a = d_link[i].a;
    auto b = d_link[i].b;
    if (a == b) return;

    force(d_X, a, b, strength, d_dX);
}

// First template is required to work around bug in CUDA 9.2 and 10.
template<typename Pt>
void link_forces(Links& links, const Pt* __restrict__ d_X, Pt* d_dX)
{
    link<Pt, linear_force<Pt>><<<(links.get_d_n() + 32 - 1) / 32, 32>>>(
        d_X, d_dX, links.d_link, links.get_d_n(), links.strength);
}

template<typename Pt, Link_force<Pt> force>
void link_forces(Links& links, const Pt* __restrict__ d_X, Pt* d_dX)
{
    link<Pt, force><<<(links.get_d_n() + 32 - 1) / 32, 32>>>(
        d_X, d_dX, links.d_link, links.get_d_n(), links.strength);
}


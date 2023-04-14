using WaterLily
using Test
using CUDA: cu, @allowscalar, allowscalar
allowscalar(false)

@testset "util.jl" begin
    I = CartesianIndex(1,2,3,4)
    @test I+δ(3,I) == CartesianIndex(1,2,4,4)

    p = Float64[i+j  for i ∈ 1:4, j ∈ 1:5]
    @test inside(p) == CartesianIndices((2:3,2:4))
    @test L₂(p) == 187

    p = p |> cu
    @test L₂(p) == 187 # unchanged!

    using StaticArrays
    @test loc(3,CartesianIndex(3,4,5)) == SVector(3,4,4.5)
    I = CartesianIndex(rand(2:10,3)...)
    @test loc(0,I) == SVector(I.I...)

    ex,sym = :(a[I,i] = Math.add(p.b[I],func(I,q))),[]
    WaterLily.grab!(sym,ex)
    @test ex == :(a[I, i] = Math.add(b[I], func(I, q)))
    @test sym == [:a, :I, :i, :(p.b), :q]

    for f ∈ [identity, cu]
        u = zeros(5,5,2) |> f
        apply!((i,x)->x[i],u)
        @allowscalar @test [u[i,j,1].-(i-0.5) for i in 1:3, j in 1:3]==zeros(3,3)

        Ng, D, U = (6, 6), 2, (1.0, 0.5)
        u = rand(Ng..., D) |> f # vector
        σ = rand(Ng...) |> f # scalar
        BC!(u, U)
        BC!(σ)
        allowscalar() do
            @test all(u[1, :, 1] .== U[1]) && all(u[2, :, 1] .== U[1]) && all(u[end, :, 1] .== U[1]) &&
                all(u[3:end-1, 1, 1] .== u[3:end-1, 2, 1]) && all(u[3:end-1, end, 1] .== u[3:end-1, end-1, 1])
            @test all(u[:, 1, 2] .== U[2]) && all(u[:, 2, 2] .== U[2]) && all(u[:, end, 2] .== U[2]) &&
                all(u[1, 3:end-1, 2] .== u[2, 3:end-1, 2]) && all(u[end, 3:end-1, 2] .== u[end-1, 3:end-1, 2])
            @test all(σ[1, 2:end-1] .== σ[2, 2:end-1]) && all(σ[end, 2:end-1] .== σ[end-1, 2:end-1]) &&
                all(σ[2:end-1, 1] .== σ[2:end-1, 2]) && all(σ[2:end-1, end] .== σ[2:end-1, end-1])
        end
    end
end

function Poisson_setup(poisson,N;f=identity,T=Float32,D=length(N))
    c = ones(T,N...,D) |> f
    BC!(c, ntuple(zero,D))
    x = zeros(T,N) |> f
    pois = poisson(x,c)
    soln = map(I->T(I.I[1]),CartesianIndices(N)) |> f
    solver!(pois,mult(pois,soln))
    I = first(inside(x))
    @allowscalar @. x -= soln+(x[I]-soln[I])
    return L₂(x)/L₂(soln),pois
end

@testset "Poisson.jl" begin
    for f ∈ [identity,cu]
        err,pois = Poisson_setup(Poisson,(5,5);f)
        @test @allowscalar parent(pois.D)==f(Float32[0 0 0 0 0; 0 -2 -3 -2 0; 0 -3 -4 -3 0;  0 -2 -3 -2 0; 0 0 0 0 0])
        @test @allowscalar parent(pois.iD)≈f(Float32[0 0 0 0 0; 0 -1/2 -1/3 -1/2 0; 0 -1/3 -1/4 -1/3 0;  0 -1/2 -1/3 -1/2 0; 0 0 0 0 0])
        @test err < 1e-5
        err,pois = Poisson_setup(Poisson,(2^6+2,2^6+2);f)
        @test err < 1e-5
        @test pois.n[] < 512 # [511,458]
        err,pois = Poisson_setup(Poisson,(2^4+2,2^4+2,2^4+2);f)
        @test err < 1e-5
        @test pois.n[] < 57 # [56,51]
    end
end

@testset "MultiLevelPoisson.jl" begin
    I = CartesianIndex(4,3,2)
    @test all(WaterLily.down(J)==I for J ∈ WaterLily.up(I))
    @test_throws AssertionError("MultiLevelPoisson requires size=a2ⁿ, where a<31, n>2") Poisson_setup(MultiLevelPoisson,(15+2,3^4+2))

    err,pois = Poisson_setup(MultiLevelPoisson,(10,10))
    @test pois.levels[3].D == Float32[0 0 0 0; 0 -2 -2 0; 0 -2 -2 0; 0 0 0 0]
    @test err < 1e-5

    pois.levels[1].L[5:6,:,1].=0
    WaterLily.update!(pois)
    @test pois.levels[3].D == Float32[0 0 0 0; 0 -1 -1 0; 0 -1 -1 0; 0 0 0 0]

    for f ∈ [identity,cu]
        err,pois = Poisson_setup(MultiLevelPoisson,(2^6+2,2^6+2);f)
        @test err < 1e-5
        @test pois.n[] < 33 # [7,32]

        err,pois = Poisson_setup(MultiLevelPoisson,(2^4+2,2^4+2,2^4+2);f)
        @test err < 1e-5
        @test pois.n[] < 12 # [6,11]
    end
end

@testset "Flow.jl" begin
    # Impulsive flow in a box
    U = (2/3, -1/3) 
    N = (2^4, 2^4)
    for f ∈ [identity, cu]
        a = Flow(N, U; f, T=Float32)
        mom_step!(a, MultiLevelPoisson(a.p,a.μ₀))
        @test L₂(a.u[:,:,1].-U[1]) < 2e-5
        @test L₂(a.u[:,:,2].-U[2]) < 1e-5
    end
end

@testset "Body.jl" begin
    @test WaterLily.μ₀(3,6)==WaterLily.μ₀(0.5,1)
    @test WaterLily.μ₀(0,1)==0.5
    @test WaterLily.μ₁(0,2)==2*(1/4-1/π^2)
end

using KernelAbstractions
@testset "AutoBody.jl" begin
    norm2(x) = √sum(abs2,x)
    # test AutoDiff in 2D and 3D
    body1 = AutoBody((x,t)->norm2(x)-2-t)
    @test all(measure(body1,[√2.,√2.],0.).≈(0,[√.5,√.5],[0.,0.]))
    @test all(measure(body1,[2.,0.,0.],1.).≈(-1.,[1.,0.,0.],[0.,0.,0.]))
    body2 = AutoBody((x,t)->norm2(x)-2,(x,t)->x.+t^2)
    @test all(measure(body2,[√2.,√2.],0.).≈(0,[√.5,√.5],[0.,0.]))
    @test all(measure(body2,[1.,-1.,-1.],1.).≈(0.,[1.,0.,0.],[-2.,-2.,-2.]))

    #test booleans
    @test all(measure(body1+body2,[-√2.,-√2.],1.).≈(-√2.,[-√.5,-√.5],[-2.,-2.]))
    @test all(measure(body1-body2,[-√2.,-√2.],1.).≈(√2.,[√.5,√.5],[-2.,-2.]))

    # test fast_sdf matches exhaustive sdf
    dims = (2^5,2^5)
    sdf(x) = norm2(x.-2^4)-4π
    a = zeros(dims); WaterLily.fast_sdf!(sdf,a); BC!(a)
    b = zeros(dims); @inside b[I] = sdf(WaterLily.loc(0,I)); BC!(b)
    @test all(@. clamp(a,-2,2)==clamp(b,-2,2))
end

using StaticArrays
function get_flow(N,f)
    a = Flow((N,N),(1.,0.);f,T=Float32);
    sdf(x,t) = √sum(abs2,x.-N÷2)-N÷4
    map(x,t) = x.-SVector(t,0)
    WaterLily.measure!(a,AutoBody(sdf,map))
    return a
end

@testset "Flow.jl with Body.jl" begin
    # Horizontally moving body
    for f ∈ [identity,cu]
        a = get_flow(20,f)
        @test @allowscalar all(@. abs(a.μ₀[3:end-1,2:end-1,1]-0.5)==0.5 || a.V[3:end-1,2:end-1,1] == 1)
        @test @allowscalar all(a.V[:,:,2] .== 0)
        mom_step!(a,Poisson(a.p,a.μ₀))
        @test mapreduce(abs2,+,a.u[:,5,1].-1) < 2e-5
    end
end

# @testset "Metrics.jl" begin
#     I = CartesianIndex(2,3,4)
#     u = zeros(3,4,5,3); apply!((i,x)->x[i]+prod(x),u)
#     @test WaterLily.ke(I,u)==0.5*(26^2+27^2+28^2)
#     @test WaterLily.ke(I,u,[2,3,4])===1.5*24^2
#     @test [WaterLily.∂(i,j,I,u)
#             for i in 1:3, j in 1:3] == [13 8 6; 12 9 6; 12 8 7]
#     @test WaterLily.λ₂(I,u)≈1
#     ω = [8-6,6-12,12-8]
#     @test WaterLily.curl(2,I,u)==ω[2]
#     @test WaterLily.ω(I,u)==ω
#     @test WaterLily.ω_mag(I,u)==sqrt(sum(abs2,ω))
#     @test WaterLily.ω_θ(I,[0,0,1],[2,2,2],u)==-ω[1]

#     body = AutoBody((x,t)->√sum(abs2,x .- 2^6) - 2^5)
#     p = ones(2^7,2^7)
#     @inside p[I] = sum(I.I[2])
#     @test sum(abs2,WaterLily.∮nds(p,body)/(π*2^10).-(0,1))<1e-6
#     @inside p[I] = cos(atan(reverse(loc(0,I) .- 2^6)...))
#     @test sum(abs2,WaterLily.∮nds(p,body)/(π*2^5).-(1,0))<1e-6
# end

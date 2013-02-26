#include <iostream>
#include <fstream>

#include <cufft.h>
#include <stdio.h>

#define N 8

#define PI 3.14159265359

#define SQR(A) ((A)*(A))
#define P3M_BRILLOUIN 1

using namespace std;

typedef struct {
  int n;
  double *pos;
  double *q;
  double *f_x;
  double *f_y;
  double *f_z;
  double alpha;
  int cao;
  int mesh;
  double box;
} data_t;

typedef struct {
  cufftHandle plan;
  cufftDoubleComplex *charge_mesh;
  cufftDoubleComplex *force_mesh;
  double *g_hat_d;
  double *pos_d;
  double *q_d;
  double *forces_d;
} p3m_cuda_state_t;

data_t *read_reference( char *filename ) {
  ifstream f;
  int i=0;
  data_t *d = (data_t *)malloc(sizeof(data_t));

  f.open(filename);

  f >> d->n;
  f >> d->cao;
  f >> d->mesh;
  f >> d->alpha;
  f >> d->box;

  d->pos = (double *)malloc(3*d->n*sizeof(double));
  d->q = (double *)malloc(d->n*sizeof(double));
  d->f_x = (double *)malloc(d->n*sizeof(double));
  d->f_y = (double *)malloc(d->n*sizeof(double));
  d->f_z = (double *)malloc(d->n*sizeof(double));

  while(f.good()) {
    f >> d->pos[3*i + 0];
    f >> d->pos[3*i + 1];
    f >> d->pos[3*i + 2];
    f >> d->q[i];
    f >> d->f_x[i];
    f >> d->f_y[i];
    f >> d->f_z[i];
    i++;
  }
  if(i-1 != d->n)
    printf("Warning, not enought particles in file. (%d of %d)\n", i, d->n);

  return d;
}


__device__ __host__ inline double sinc(double d)
{
  double PId = PI*d;
  return (d == 0.0) ? 1.0 : sin(PId)/PId;
}

void Aliasing_sums_ik ( int cao, double box, double alpha, int mesh, int NX, int NY, int NZ,
                        double *Zaehler, double *Nenner ) {
    double S1,S2,S3;
    double fak1,fak2,zwi;
    int    MX,MY,MZ;
    double NMX,NMY,NMZ;
    double NM2;
    double expo, TE;
    double Leni = 1.0/box;

    fak1 = 1.0/ ( double ) mesh;
    fak2 = SQR ( PI/ ( alpha ) );

    Zaehler[0] = Zaehler[1] = Zaehler[2] = *Nenner = 0.0;

    for ( MX = -P3M_BRILLOUIN; MX <= P3M_BRILLOUIN; MX++ ) {
      NMX = ( ( NX > mesh/2 ) ? NX - mesh : NX ) + mesh*MX;
      S1 = pow ( sinc(fak1*NMX ), 2*cao );
      for ( MY = -P3M_BRILLOUIN; MY <= P3M_BRILLOUIN; MY++ ) {
	NMY = ( ( NY > mesh/2 ) ? NY - mesh : NY ) + mesh*MY;
	S2   = S1*pow ( sinc (fak1*NMY ), 2*cao );
	for ( MZ = -P3M_BRILLOUIN; MZ <= P3M_BRILLOUIN; MZ++ ) {
	  NMZ = ( ( NZ > mesh/2 ) ? NZ - mesh : NZ ) + mesh*MZ;
	  S3   = S2*pow ( sinc( fak1*NMZ ), 2*cao );

	  NM2 = SQR ( NMX*Leni ) + SQR ( NMY*Leni ) + SQR ( NMZ*Leni );
	  *Nenner += S3;

	  expo = fak2*NM2;
	  TE = exp ( -expo );
	  zwi  = S3 * TE/NM2;
	  Zaehler[0] += NMX*zwi*Leni;
	  Zaehler[1] += NMY*zwi*Leni;
	  Zaehler[2] += NMZ*zwi*Leni;
	}
      }
    }
}

/* Calculate influence function */
void Influence_function_berechnen_ik ( int cao, int mesh, double box, double alpha, double *G_hat ) {

  int    NX,NY,NZ;
  double Dnx,Dny,Dnz;
  double Zaehler[3]={0.0,0.0,0.0},Nenner=0.0;
  double zwi;
  int ind = 0;
  double Leni = 1.0/box;

  for ( NX=0; NX<mesh; NX++ ) {
    for ( NY=0; NY<mesh; NY++ ) {
      for ( NZ=0; NZ<mesh; NZ++ ) {
	ind = NX*mesh*mesh + NY * mesh + NZ;
	  
	if ( ( NX==0 ) && ( NY==0 ) && ( NZ==0 ) )
	  G_hat[ind]=0.0;
	else if ( ( NX% ( mesh/2 ) == 0 ) && ( NY% ( mesh/2 ) == 0 ) && ( NZ% ( mesh/2 ) == 0 ) )
	  G_hat[ind]=0.0;
	else {
	  Aliasing_sums_ik ( cao, box, alpha, mesh, NX, NY, NZ, Zaehler, &Nenner );
		  
	  Dnx = ( NX > mesh/2 ) ? NX - mesh : NX;
	  Dny = ( NY > mesh/2 ) ? NY - mesh : NY;
	  Dnz = ( NZ > mesh/2 ) ? NZ - mesh : NZ;
	    
	  zwi  = Dnx*Zaehler[0]*Leni + Dny*Zaehler[1]*Leni + Dnz*Zaehler[2]*Leni;
	  zwi /= ( ( SQR ( Dnx*Leni ) + SQR ( Dny*Leni ) + SQR ( Dnz*Leni ) ) * SQR ( Nenner ) );
	  G_hat[ind] = 2.0 * zwi / PI;
	}
      }
    }
  }
}


__device__ inline int wrap_index(const int ind, const int mesh) {
  if(ind < 0)
    return ind + mesh;
  else if(ind >= mesh)
    return ind - mesh;
  else 
    return ind;	   
}

__device__ double atomicAdd(double* address, double val)
{
    unsigned long long int* address_as_ull =
                              (unsigned long long int*)address;
    unsigned long long int old = *address_as_ull, assumed;
    do {
        assumed = old;
        old = atomicCAS(address_as_ull, assumed,
                        __double_as_longlong(val +
                               __longlong_as_double(assumed)));
    } while (assumed != old);
    return __longlong_as_double(old);
}

__device__ double caf(int i, double x, int cao_value) {
  switch (cao_value) {
  case 1 : return 1.0;
  case 2 : {
    switch (i) {
    case 0: return 0.5-x;
    case 1: return 0.5+x;
    default:
      return 0.0;
    }
  } 
  case 3 : { 
    switch (i) {
    case 0: return 0.5*SQR(0.5 - x);
    case 1: return 0.75 - SQR(x);
    case 2: return 0.5*SQR(0.5 + x);
    default:
      return 0.0;
    }
  case 4 : { 
    switch (i) {
    case 0: return ( 1.0+x*( -6.0+x*( 12.0-x* 8.0)))/48.0;
    case 1: return (23.0+x*(-30.0+x*(-12.0+x*24.0)))/48.0;
    case 2: return (23.0+x*( 30.0+x*(-12.0-x*24.0)))/48.0;
    case 3: return ( 1.0+x*(  6.0+x*( 12.0+x* 8.0)))/48.0;
    default:
      return 0.0;
    }
  }
  case 5 : {
    switch (i) {
    case 0: return (  1.0+x*( -8.0+x*(  24.0+x*(-32.0+x*16.0))))/384.0;
    case 1: return ( 19.0+x*(-44.0+x*(  24.0+x*( 16.0-x*16.0))))/ 96.0;
    case 2: return (115.0+x*       x*(-120.0+x*       x*48.0))  /192.0;
    case 3: return ( 19.0+x*( 44.0+x*(  24.0+x*(-16.0-x*16.0))))/ 96.0;
    case 4: return (  1.0+x*(  8.0+x*(  24.0+x*( 32.0+x*16.0))))/384.0;
    default:
      return 0.0;
    }
  }
  case 6 : {
    switch (i) {
    case 0: return (  1.0+x*( -10.0+x*(  40.0+x*( -80.0+x*(  80.0-x* 32.0)))))/3840.0;
    case 1: return (237.0+x*(-750.0+x*( 840.0+x*(-240.0+x*(-240.0+x*160.0)))))/3840.0;
    case 2: return (841.0+x*(-770.0+x*(-440.0+x*( 560.0+x*(  80.0-x*160.0)))))/1920.0;
    case 3: return (841.0+x*(+770.0+x*(-440.0+x*(-560.0+x*(  80.0+x*160.0)))))/1920.0;
    case 4: return (237.0+x*( 750.0+x*( 840.0+x*( 240.0+x*(-240.0-x*160.0)))))/3840.0;
    case 5: return (  1.0+x*(  10.0+x*(  40.0+x*(  80.0+x*(  80.0+x* 32.0)))))/3840.0;
    default:
      return 0.0;
    }
  }
  case 7 : {
    switch (i) {
    case 0: return (    1.0+x*(   -12.0+x*(   60.0+x*( -160.0+x*(  240.0+x*(-192.0+x* 64.0))))))/46080.0;
    case 1: return (  361.0+x*( -1416.0+x*( 2220.0+x*(-1600.0+x*(  240.0+x*( 384.0-x*192.0))))))/23040.0;
    case 2: return (10543.0+x*(-17340.0+x*( 4740.0+x*( 6880.0+x*(-4080.0+x*(-960.0+x*960.0))))))/46080.0;
    case 3: return ( 5887.0+x*          x*(-4620.0+x*         x*( 1680.0-x*        x*320.0)))   /11520.0;
    case 4: return (10543.0+x*( 17340.0+x*( 4740.0+x*(-6880.0+x*(-4080.0+x*( 960.0+x*960.0))))))/46080.0;
    case 5: return (  361.0+x*(  1416.0+x*( 2220.0+x*( 1600.0+x*(  240.0+x*(-384.0-x*192.0))))))/23040.0;
    case 6: return (    1.0+x*(    12.0+x*(   60.0+x*(  160.0+x*(  240.0+x*( 192.0+x* 64.0))))))/46080.0;
    default:
      return 0.0;
    }
  }
  }}
  return 0.0;
}

__global__ void assign_charges(const double * const pos, const double * const q,
cufftDoubleComplex *mesh, const int m_size, const int cao, const double pos_shift, const
double hi) {
      /** id of the particle **/
      int id = blockIdx.x;
      /** position relative to the closest gird point **/
      double m_pos[3];
      /** index of the nearest mesh point **/
      int nmp_x, nmp_y, nmp_z;      

      m_pos[0] = pos[3*id + 0] * hi - pos_shift;
      m_pos[1] = pos[3*id + 1] * hi - pos_shift;
      m_pos[2] = pos[3*id + 2] * hi - pos_shift;

      nmp_x = (int) floor(m_pos[0] + 0.5);
      nmp_y = (int) floor(m_pos[1] + 0.5);
      nmp_z = (int) floor(m_pos[2] + 0.5);

      m_pos[0] -= nmp_x;
      m_pos[1] -= nmp_y;
      m_pos[2] -= nmp_z;

      nmp_x = wrap_index(nmp_x + threadIdx.x, m_size);
      nmp_y = wrap_index(nmp_y + threadIdx.y, m_size);
      nmp_z = wrap_index(nmp_z + threadIdx.z, m_size);

      /* printf("id %d, m { %d %d %d }: weight = %lf, nmp[] = (%d %d %d), pos[] = (%lf %lf %lf)\n", id, threadIdx.x, threadIdx.y, threadIdx.z, caf(threadIdx.x, m_pos[0], cao)*caf(threadIdx.y, m_pos[1], cao)*caf(threadIdx.z, m_pos[2], cao)*q[id], nmp_x, nmp_y, nmp_z, m_pos[0], m_pos[1], m_pos[2]); */

      atomicAdd( &(mesh[m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z].x), caf(threadIdx.x, m_pos[0], cao)*caf(threadIdx.y, m_pos[1], cao)*caf(threadIdx.z, m_pos[2], cao)*q[id]);
}

__global__ void assign_forces(const double * const pos, const double * const q,
cufftDoubleComplex *mesh, const int m_size, const int cao, const double pos_shift, const
			      double hi, double *force, double prefactor) {
      /** id of the particle **/
      int id = blockIdx.x;
      /** position relative to the closest gird point **/
      double m_pos[3];
      /** index of the nearest mesh point **/
      int nmp_x, nmp_y, nmp_z;      

      m_pos[0] = pos[3*id + 0] * hi - pos_shift;
      m_pos[1] = pos[3*id + 1] * hi - pos_shift;
      m_pos[2] = pos[3*id + 2] * hi - pos_shift;

      nmp_x = (int) floor(m_pos[0] + 0.5);
      nmp_y = (int) floor(m_pos[1] + 0.5);
      nmp_z = (int) floor(m_pos[2] + 0.5);

      m_pos[0] -= nmp_x;
      m_pos[1] -= nmp_y;
      m_pos[2] -= nmp_z;

      nmp_x = wrap_index(nmp_x + threadIdx.x, m_size);
      nmp_y = wrap_index(nmp_y + threadIdx.y, m_size);
      nmp_z = wrap_index(nmp_z + threadIdx.z, m_size);

      /* printf("id %d, m { %d %d %d }: weight = %lf, nmp[] = (%d %d %d), pos[] = (%lf %lf %lf)\n", id, threadIdx.x, threadIdx.y, threadIdx.z, caf(threadIdx.x, m_pos[0], cao)*caf(threadIdx.y, m_pos[1], cao)*caf(threadIdx.z, m_pos[2], cao)*q[id], nmp_x, nmp_y, nmp_z, pos[0], pos[1], pos[2]); */

      atomicAdd( &(force[id]), -prefactor*mesh[m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z].x*caf(threadIdx.x, m_pos[0], cao)*caf(threadIdx.y, m_pos[1], cao)*caf(threadIdx.z, m_pos[2], cao)*q[id]);
}

__global__ void influence_function( double *G_hat, double box, int cao, int mesh, double alpha ) {
  int n[3];
  int linear_index;
  double nom[3] = { 0.0, 0.0, 0.0 }, dnom = 0.0;
  double fak = SQR( PI / alpha );
  int mx, my, mz;
  double box_i = 1./box;
  int nshift[3];
  int nmx, nmy, nmz;
  double zwi, nm2;
  double S1, S2, S3;

  n[0] = blockIdx.x;
  n[1] = blockIdx.y;
  n[2] = threadIdx.x;

  nshift[0] = (n[0] > mesh/2) ? n[0] - mesh : n[0];
  nshift[1] = (n[1] > mesh/2) ? n[1] - mesh : n[1];
  nshift[2] = (n[2] > mesh/2) ? n[2] - mesh : n[2];

  linear_index = SQR(mesh)*n[0] + mesh * n[1] + n[2];

  if( (n[0] == 0) && ( n[1] == 0) && n[2] == 0) {
    G_hat[linear_index] = 0.0;
    return;
  }

  if( (n[0] % (mesh/2) == 0)  && (n[1] % (mesh/2) == 0)  && (n[2] % (mesh/2) == 0)) {
    G_hat[linear_index] = 0.0;
    return;
  } 

  for ( mx = -P3M_BRILLOUIN; mx <= P3M_BRILLOUIN; mx++ ) {
    nmx = nshift[0] + mesh*mx;
    S1 = pow ( sinc ( box_i*nmx ), 2*cao );
    for ( my = -P3M_BRILLOUIN; my <= P3M_BRILLOUIN; my++ ) {
      nmy = nshift[1] + mesh*my;
      S2   = S1*pow ( sinc ( box_i*nmy ), 2*cao );
      for ( mz = -P3M_BRILLOUIN; mz <= P3M_BRILLOUIN; mz++ ) {
	nmz = nshift[2] + mesh*mz;
	S3   = S2*pow ( sinc ( box_i*nmz ), 2*cao );

	nm2 = SQR ( nmx*box_i ) + SQR ( nmy*box_i ) + SQR ( nmz*box_i );
	dnom += S3;

	zwi  = S3 * exp ( -fak*nm2 )/nm2;

	nom[0] += nmx*zwi*box_i;
	nom[1] += nmy*zwi*box_i;
	nom[2] += nmz*zwi*box_i;
      }
    }
  }
  
  zwi = box_i * (nshift[0]*nom[0] + nshift[1]*nom[1] + nshift[2]*nom[2]);
  zwi /= (SQR(nshift[0]) + SQR(nshift[1]) + SQR(nshift[2])) * SQR(box_i) *SQR(dnom);

  printf("influence_function(%d %d %d) = %lf, nm2 = %lf, nm[] = (%d %d %d), nshift[] = (%d %d %d), dnom = %e\n",
	 n[0], n[1], n[2], zwi, nm2, nmx, nmy, nmz, nshift[0], nshift[1], nshift[2], dnom);
  
  G_hat[linear_index] = 2.0 * zwi / PI;

  return;
}

__global__ void apply_influence_function( cufftDoubleComplex *mesh, int mesh_size, double *G_hat ) {
  int linear_index = mesh_size*mesh_size*blockIdx.x + mesh_size * blockIdx.y + threadIdx.x;
  mesh[linear_index].x *= G_hat[linear_index];
  mesh[linear_index].y *= G_hat[linear_index];
}

__global__ void apply_diff_op( cufftDoubleComplex *mesh, const int mesh_size, cufftDoubleComplex *force_mesh,  const double box, const int dim ) {
  int linear_index = mesh_size*mesh_size*blockIdx.x + mesh_size * blockIdx.y + threadIdx.x;
  int n;

  switch( dim ) {
  case 0:
    n = blockIdx.x;
    break;
  case 1:
    n = blockIdx.y;
    break;
  case 2:
    n = threadIdx.x;
    break;
  }

  n = ( n == mesh_size/2 ) ? 0.0 : n;
  n = ( n > mesh_size/2) ? n - mesh_size : n;
 
  force_mesh[linear_index].x =  -2.0 * PI * n * mesh[linear_index].y / box;
  force_mesh[linear_index].y =   2.0 * PI * n * mesh[linear_index].x / box;
}

/* __global__ void assign_charges(const double * const pos, const double * const q, */
/* cufftDoubleComplex *mesh, const int m_size, const int cao, const double pos_shift, const */
/* double hi) { */

p3m_cuda_state_t p3m_cuda_init( data_t *d ) {
  p3m_cuda_state_t state;
  double *g_hat_h = (double *)malloc(d->mesh*d->mesh*d->mesh*sizeof(double));

  cudaMalloc((void**)&(state.g_hat_d), sizeof(double)*d->mesh*d->mesh*d->mesh);
  if (cudaGetLastError() != cudaSuccess){
    fprintf(stderr, "p3m_cuda: Failed to allocate\n");
  }

  cudaMalloc((void**)&(state.charge_mesh), sizeof(cufftDoubleComplex)*d->mesh*d->mesh*d->mesh);
  if (cudaGetLastError() != cudaSuccess){
    fprintf(stderr, "p3m_cuda: Failed to allocate\n");
  }

  cudaMalloc((void**)&(state.force_mesh), sizeof(cufftDoubleComplex)*d->mesh*d->mesh*d->mesh);
  if (cudaGetLastError() != cudaSuccess){
    fprintf(stderr, "p3m_cuda: Failed to allocate\n");
  }

  cudaMalloc((void**)&(state.pos_d), 3*d->n*sizeof(double));
  if (cudaGetLastError() != cudaSuccess){
    fprintf(stderr, "p3m_cuda: Failed to allocate\n");
  }
  cudaMalloc((void**)&(state.q_d), d->n*sizeof(double));
  if (cudaGetLastError() != cudaSuccess){
    fprintf(stderr, "p3m_cuda: Failed to allocate\n");
  }
  cudaMalloc((void**)&(state.forces_d), d->n*sizeof(double));
  if (cudaGetLastError() != cudaSuccess){
    fprintf(stderr, "p3m_cuda: Failed to allocate\n");
  }

  Influence_function_berechnen_ik( d->cao, d->mesh, d->box, d->alpha, g_hat_h );  

  cudaMemcpy( state.g_hat_d, g_hat_h, d->mesh*d->mesh*d->mesh*sizeof(double), cudaMemcpyHostToDevice);

  if (cufftPlan3d(&(state.plan), d->mesh, d->mesh, d->mesh, CUFFT_Z2Z) != CUFFT_SUCCESS){
    fprintf(stderr, "CUFFT error: Plan creation failed");
  }

  return state;
}

int main(int argc, char **argv) {
  data_t *d;
  p3m_cuda_state_t state;
  double *forces_h;
  
  d = read_reference(argv[1]);

  forces_h = (double*)malloc(3*d->n*sizeof(double));

  state = p3m_cuda_init(d);

  cudaMemcpy( state.pos_d, d->pos, 3*d->n*sizeof(double), cudaMemcpyHostToDevice);
  cudaMemcpy( state.q_d, d->q, d->n*sizeof(double), cudaMemcpyHostToDevice);

  // prepare influence function
  dim3 blockDim(d->mesh, d->mesh, 1);
  dim3 thdDim( d->mesh, 1, 1);

  if (cudaThreadSynchronize() != cudaSuccess){
    fprintf(stderr, "Cuda error: Failed to synchronize\n");
    return 0;
  }

  cudaMemset( state.charge_mesh, 0, d->mesh*d->mesh*d->mesh*sizeof(cufftDoubleComplex));
  
  dim3 caoBlock(d->cao, d->cao, d->cao);

  assign_charges<<<d->n, caoBlock>>>( state.pos_d, state.q_d, state.charge_mesh, d->mesh, d->cao,(double)((d->cao-1)/2), d->mesh/d->box);

  cudaThreadSynchronize();

  if (cufftExecZ2Z(state.plan, state.charge_mesh, state.charge_mesh, CUFFT_FORWARD) != CUFFT_SUCCESS){
    fprintf(stderr, "CUFFT error: ExecZ2Z Forward failed\n");
    return 0;
  }

  if (cudaThreadSynchronize() != cudaSuccess){
    fprintf(stderr, "Cuda error: Failed to synchronize\n");
    return 0;
  }

  apply_influence_function<<<blockDim, thdDim>>>( state.charge_mesh, d->mesh, state.g_hat_d);

  for(int dim = 0; dim < 3; dim++) {
    if (cudaThreadSynchronize() != cudaSuccess){
      fprintf(stderr, "Cuda error: Failed to synchronize\n");
      return 0;
    }

    apply_diff_op<<<blockDim, thdDim>>>( state.charge_mesh, d->mesh, state.force_mesh, d->box, dim);

    if (cudaThreadSynchronize() != cudaSuccess){
      fprintf(stderr, "Cuda error: Failed to synchronize diff_op\n");
      return 0;
    }

    /* Use the CUFFT plan to transform the signal in place. */
    if (cufftExecZ2Z(state.plan, state.force_mesh, state.force_mesh, CUFFT_INVERSE) != CUFFT_SUCCESS){
      fprintf(stderr, "CUFFT error: ExecZ2Z Backward failed\n");
      return 0;
    }

    if (cudaThreadSynchronize() != cudaSuccess){
      fprintf(stderr, "Cuda error: Failed to synchronize back\n");
      return 0;
    }

    cudaMemset(state.forces_d, 0, d->n*sizeof(double));

    assign_forces<<< d->n, caoBlock>>>( state.pos_d, state.q_d, state.force_mesh, d->mesh, d->cao, (double)((d->cao-1)/2), d->mesh/d->box, state.forces_d, 1.0 / ( 2.0 *  d->box * d->box * d->box));

    cudaMemcpy( (forces_h + d->n*dim), state.forces_d, d->n*sizeof(double), cudaMemcpyDeviceToHost);
  }

  double rms = 0.0;

  for(int i = 0; i < d->n; i++) {
    printf("part %d, pos %lf %lf %lf\n", i, d->pos[3*i], d->pos[3*i+1], d->pos[3*i+2]);
    printf("%lf %lf %lf\n", d->f_x[i], d->f_y[i], d->f_z[i]);
    printf("%lf %lf %lf\n", forces_h[i + (0*d->n)], forces_h[i + (1*d->n)], forces_h[i + (2*d->n)]);
    rms += SQR(d->f_x[i] -forces_h[i + (0*d->n)]);
    rms += SQR(d->f_y[i] -forces_h[i + (1*d->n)]);
    rms += SQR(d->f_z[i] -forces_h[i + (2*d->n)]);
  }
  printf("rms_k %e\n", sqrt(rms)/d->n);
}


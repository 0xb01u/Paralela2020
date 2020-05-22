// User: g204@157.88.139.133 
// ExecutionRequest[P:'extinguishingV19.cu',P:1,T:1,args:'',q:'cudalb'] 
// May 16 2019 16:46:03
#include "cputils.h" // Added by tablon
/*
 * Simplified simulation of fire extinguishing
 *
 * Computacion Paralela, Grado en Informatica (Universidad de Valladolid)
 * 2018/2019
 *
 * v1.4
 *
 * (c) 2019 Arturo Gonzalez Escribano
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <cputils.h>

#define RADIUS_TYPE_1		3
#define RADIUS_TYPE_2_3		9
#define THRESHOLD	0.1f

/* Structure to store data of an extinguishing team */
typedef struct {
	int x,y;
	int type;
	int target;
} Team;

/* Structure to store data of a fire focal point */
typedef struct {
	int x,y;
	int start;
	int heat;
	int active; // States: 0 Not yet activated; 1 Active; 2 Deactivated by a team
} FocalPoint;

/* Macro function to simplify accessing with two coordinates to a flattened array */
#define accessMat( arr, exp1, exp2 )	arr[ (exp1) * columns + (exp2) ]

/*Realiza la copia de srface en surfaceCopy*/
__global__ void copia(float *surface, float *surfaceCopy, int rows, int columns)
{
	/* Fórmula para calcular la posición */	
	int pos_x=(threadIdx.x+blockIdx.x*blockDim.x)+(threadIdx.y+blockIdx.y*blockDim.y)*blockDim.x*gridDim.x;

	/* Copia a surfaceCopy */
	if(pos_x<(rows*columns)){
		surfaceCopy[pos_x]=surface[pos_x];
	}
}

//__global__ void puntosfocales(float *surface, float *dfocales, int numfocal)
//{
//	/* Fórmula para calcular la posición */	
//	int pos_x=(threadIdx.x+blockIdx.x*blockDim.x)+(threadIdx.y+blockIdx.y*blockDim.y)*blockDim.x*gridDim.x;
//	if(dfocales[pos_x]<numfocal){
//		if(dfocales[pos_x].active==1){
//			surface[pos_x]=dfocales[pos_x].heat;
//		}
//	}
//}

/*
			for( i=0; i<num_focal; i++ ) {
				if ( focal[i].active != 1 ) continue;
				int x = focal[i].x;
				int y = focal[i].y;
				accessMat( surface, x, y ) = focal[i].heat;
			}
			*/

/*Realiza la actualización de calor*/
__global__ void updatesurface(float *dSurface, float *dSurfaceCopy, int rows, int columns){

	 /* Posición global del hilo */
	int position = (threadIdx.x + blockIdx.x * blockDim.x) + (threadIdx.y + blockIdx.y * blockDim.y) * blockDim.x * gridDim.x;

	int first = columns - 1;
	int last = columns * (rows - 1);

	if ( position < (rows*columns) && position != 0 && position > first && position < last && position % columns != 0 && position % columns != columns - 1 ){
		int i = position / columns;
		int j = position % columns;
		accessMat( dSurface, i, j ) = (
		accessMat( dSurfaceCopy, i-1, j ) +
		accessMat( dSurfaceCopy, i+1, j ) +
		accessMat( dSurfaceCopy, i, j-1 ) +
		accessMat( dSurfaceCopy, i, j+1 ) ) / 4;
		}
}
/*__device__ void warpReduce(volatile float* sdata, int tid) {
	sdata[tid] =fmax(sdata[tid],sdata[tid + 32]);
	sdata[tid]  =fmax(sdata[tid],sdata[tid + 16]);
	sdata[tid]  =fmax(sdata[tid],sdata[tid + 8]);
	sdata[tid]  =fmax(sdata[tid],sdata[tid + 4]);
	sdata[tid]  =fmax(sdata[tid],sdata[tid + 2]);
	sdata[tid]  =fmax(sdata[tid],sdata[tid + 1]);
}*/
template <unsigned int blockSize>
__device__ void warpReduce(volatile float *sdata, int tid) {
	if (blockSize >= 64) sdata[tid] =fmax(sdata[tid],sdata[tid + 32]);
	if (blockSize >= 32) sdata[tid]  =fmax(sdata[tid],sdata[tid + 16]);
	if (blockSize >= 16) sdata[tid]  =fmax(sdata[tid],sdata[tid + 8]);
	if (blockSize >= 8) sdata[tid]  =fmax(sdata[tid],sdata[tid + 4]);
	if (blockSize >= 4) sdata[tid]  =fmax(sdata[tid],sdata[tid + 2]);
	if (blockSize >= 2)sdata[tid]  =fmax(sdata[tid],sdata[tid + 1]);
}

/*Realiza la reduccion*/
template <unsigned int blockSize>
__global__ void reduce(float *dsurface, float *dsurfaceCopy, float *dmaximos, int rows, int columns){
	
	extern __shared__ float sdata[];

	int tid = threadIdx.x + threadIdx.y * blockDim.x;
	int position = (threadIdx.x + blockIdx.x * blockDim.x) + (threadIdx.y + blockIdx.y * blockDim.y) * blockDim.x * gridDim.x;
	int bloq = blockIdx.x + blockIdx.y * gridDim.x;
	int i = position / columns;
	int j = position % columns;
	if(position < (rows*columns)){
		float resta = (accessMat( dsurface, i, j ) - accessMat( dsurfaceCopy, i, j ));
		if(resta < 0.0f) resta = resta * (-1.0f);
		sdata[tid] = resta;
	} else {
		sdata[tid] = 0.0f;
	}

	__syncthreads();

	//for(unsigned int s = (blockDim.x * blockDim.y)/2; s >32 ; s>>=1){
	//
	//	if(tid <s){
	//		sdata[tid] = fmax(sdata[tid],sdata[tid + s]);
	//	}
	//	__syncthreads();
	//}
	if (blockSize >= 512) {
		if (tid < 256) { sdata[tid] =fmax(sdata[tid],sdata[tid + 256]); } __syncthreads(); }
	if (blockSize >= 256) {
		if (tid < 128) { sdata[tid] =fmax(sdata[tid],sdata[tid + 128]); } __syncthreads(); }
	if (blockSize >= 128) {
		if (tid < 64) { sdata[tid] =fmax(sdata[tid],sdata[tid + 64]); } __syncthreads(); }
	if (tid < 32) warpReduce<blockSize>(sdata, tid);

	if(tid == 0) dmaximos[bloq] = sdata[0];
}

__global__ void heat(float *dsurface, FocalPoint *dfocal, int num_focal, int columns){
	
	for( int i=0; i<num_focal; i++ ) {
		if ( dfocal[i].active != 1 ) continue;
			int x = dfocal[i].x;
			int y = dfocal[i].y;
			accessMat( dsurface, x, y ) = dfocal[i].heat;
	}
} 


/*
 * Function: Print usage line in stderr
 */
void show_usage( char *program_name ) {
	fprintf(stderr,"Usage: %s <config_file> | <command_line_args>\n", program_name );
	fprintf(stderr,"\t<config_file> ::= -f <file_name>\n");
	fprintf(stderr,"\t<command_line_args> ::= <rows> <columns> <maxIter> <numTeams> [ <teamX> <teamY> <teamType> ... ] <numFocalPoints> [ <focalX> <focalY> <focalStart> <focalTemperature> ... ]\n");
	fprintf(stderr,"\n");
}

#ifdef DEBUG
/* 
 * Function: Print the current state of the simulation 
 */
void print_status( int iteration, int rows, int columns, float *surface, int num_teams, Team *teams, int num_focal, FocalPoint *focal, float global_residual ) {
	/* 
	 * You don't need to optimize this function, it is only for pretty printing and debugging purposes.
	 * It is not compiled in the production versions of the program.
	 * Thus, it is never used when measuring times in the leaderboard
	 */
	int i,j;

	printf("Iteration: %d\n", iteration );
	printf("+");
	for( j=0; j<columns; j++ ) printf("---");
	printf("+\n");
	for( i=0; i<rows; i++ ) {
		printf("|");
		for( j=0; j<columns; j++ ) {
			char symbol;
			if ( accessMat( surface, i, j ) >= 1000 ) symbol = '*';
			else if ( accessMat( surface, i, j ) >= 100 ) symbol = '0' + (int)(accessMat( surface, i, j )/100);
			else if ( accessMat( surface, i, j ) >= 50 ) symbol = '+';
			else if ( accessMat( surface, i, j ) >= 25 ) symbol = '.';
			else symbol = '0';

			int t;
			int flag_team = 0;
			for( t=0; t<num_teams; t++ ) 
				if ( teams[t].x == i && teams[t].y == j ) { flag_team = 1; break; }
			if ( flag_team ) printf("[%c]", symbol );
			else {
				int f;
				int flag_focal = 0;
				for( f=0; f<num_focal; f++ ) 
					if ( focal[f].x == i && focal[f].y == j && focal[f].active == 1 ) { flag_focal = 1; break; }
				if ( flag_focal ) printf("(%c)", symbol );
				else printf(" %c ", symbol );
			}
		}
		printf("|\n");
	}
	printf("+");
	for( j=0; j<columns; j++ ) printf("---");
	printf("+\n");
	printf("Global residual: %f\n\n", global_residual);
}
#endif

/*
 * MAIN PROGRAM
 */
int main(int argc, char *argv[]) {
	int i,j,t;

	// Simulation data
	int rows, columns, max_iter;
	float *surface, *surfaceCopy;
	int num_teams, num_focal;
	Team *teams;
	FocalPoint *focal;

	/* 1. Read simulation arguments */
	/* 1.1. Check minimum number of arguments */
	if (argc<2) {
		fprintf(stderr,"-- Error in arguments: No arguments\n");
		show_usage( argv[0] );
		exit( EXIT_FAILURE );
	}

	int read_from_file = ! strcmp( argv[1], "-f" );
	/* 1.2. Read configuration from file */
	if ( read_from_file ) {
		/* 1.2.1. Open file */
		if (argc<3) {
			fprintf(stderr,"-- Error in arguments: file-name argument missing\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}
		FILE *args = cp_abrir_fichero( argv[2] );
		if ( args == NULL ) {
			fprintf(stderr,"-- Error in file: not found: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}	

		/* 1.2.2. Read surface and maximum number of iterations */
		int ok;
		ok = fscanf(args, "%d %d %d", &rows, &columns, &max_iter);
		if ( ok != 3 ) {
			fprintf(stderr,"-- Error in file: reading rows, columns, max_iter from file: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}

		surface = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );
		surfaceCopy = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );

		if ( surface == NULL || surfaceCopy == NULL ) {
			fprintf(stderr,"-- Error allocating: surface structures\n");
			exit( EXIT_FAILURE );
		}

		/* 1.2.3. Teams information */
		ok = fscanf(args, "%d", &num_teams );
		if ( ok != 1 ) {
			fprintf(stderr,"-- Error file, reading num_teams from file: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}
		teams = (Team *)malloc( sizeof(Team) * (size_t)num_teams );
		if ( teams == NULL ) {
			fprintf(stderr,"-- Error allocating: %d teams\n", num_teams );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_teams; i++ ) {
			ok = fscanf(args, "%d %d %d", &teams[i].x, &teams[i].y, &teams[i].type);
			if ( ok != 3 ) {
				fprintf(stderr,"-- Error in file: reading team %d from file: %s\n", i, argv[1]);
				exit( EXIT_FAILURE );
			}
		}

		/* 1.2.4. Focal points information */
		ok = fscanf(args, "%d", &num_focal );
		if ( ok != 1 ) {
			fprintf(stderr,"-- Error in file: reading num_focal from file: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}
		focal = (FocalPoint *)malloc( sizeof(FocalPoint) * (size_t)num_focal );
		if ( focal == NULL ) {
			fprintf(stderr,"-- Error allocating: %d focal points\n", num_focal );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_focal; i++ ) {
			ok = fscanf(args, "%d %d %d %d", &focal[i].x, &focal[i].y, &focal[i].start, &focal[i].heat);
			if ( ok != 4 ) {
				fprintf(stderr,"-- Error in file: reading focal point %d from file: %s\n", i, argv[1]);
				exit( EXIT_FAILURE );
			}
			focal[i].active = 0;
		}
	}
	/* 1.3. Read configuration from arguments */
	else {
		/* 1.3.1. Check minimum number of arguments */
		if (argc<6) {
			fprintf(stderr, "-- Error in arguments: not enough arguments when reading configuration from the command line\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}

		/* 1.3.2. Surface and maximum number of iterations */
		rows = atoi( argv[1] );
		columns = atoi( argv[2] );
		max_iter = atoi( argv[3] );

		surface = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );
		surfaceCopy = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );

		/* 1.3.3. Teams information */
		num_teams = atoi( argv[4] );
		teams = (Team *)malloc( sizeof(Team) * (size_t)num_teams );
		if ( teams == NULL ) {
			fprintf(stderr,"-- Error allocating: %d teams\n", num_teams );
			exit( EXIT_FAILURE );
		}
		if ( argc < num_teams*3 + 5 ) {
			fprintf(stderr,"-- Error in arguments: not enough arguments for %d teams\n", num_teams );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_teams; i++ ) {
			teams[i].x = atoi( argv[5+i*3] );
			teams[i].y = atoi( argv[6+i*3] );
			teams[i].type = atoi( argv[7+i*3] );
		}

		/* 1.3.4. Focal points information */
		int focal_args = 5 + i*3;
		if ( argc < focal_args+1 ) {
			fprintf(stderr,"-- Error in arguments: not enough arguments for the number of focal points\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}
		num_focal = atoi( argv[focal_args] );
		focal = (FocalPoint *)malloc( sizeof(FocalPoint) * (size_t)num_focal );
		if ( teams == NULL ) {
			fprintf(stderr,"-- Error allocating: %d focal points\n", num_focal );
			exit( EXIT_FAILURE );
		}
		if ( argc < focal_args + 1 + num_focal*4 ) {
			fprintf(stderr,"-- Error in arguments: not enough arguments for %d focal points\n", num_focal );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_focal; i++ ) {
			focal[i].x = atoi( argv[focal_args+i*4+1] );
			focal[i].y = atoi( argv[focal_args+i*4+2] );
			focal[i].start = atoi( argv[focal_args+i*4+3] );
			focal[i].heat = atoi( argv[focal_args+i*4+4] );
			focal[i].active = 0;
		}

		/* 1.3.5. Sanity check: No extra arguments at the end of line */
		if ( argc > focal_args+i*4+1 ) {
			fprintf(stderr,"-- Error in arguments: extra arguments at the end of the command line\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}
	}


#ifdef DEBUG
	/* 1.4. Print arguments */
	printf("Arguments, Rows: %d, Columns: %d, max_iter: %d\n", rows, columns, max_iter);
	printf("Arguments, Teams: %d, Focal points: %d\n", num_teams, num_focal );
	for( i=0; i<num_teams; i++ ) {
		printf("\tTeam %d, position (%d,%d), type: %d\n", i, teams[i].x, teams[i].y, teams[i].type );
	}
	for( i=0; i<num_focal; i++ ) {
		printf("\tFocal_point %d, position (%d,%d), start time: %d, temperature: %d\n", i, 
		focal[i].x,
		focal[i].y,
		focal[i].start,
		focal[i].heat );
	}
#endif // DEBUG

	/* 2. Select GPU and start global timer */
	cudaSetDevice(0);
	cudaDeviceSynchronize();
	double ttotal = cp_Wtime();

/*
 *
 * START HERE: DO NOT CHANGE THE CODE ABOVE THIS POINT
 *
 */
	/* Reserva de memoria para las variables del DEVICE (memoria global GPU) */
	float *dsurface;
	float *dsurfaceCopy;
	FocalPoint *dfocal;
	
	/*TAMAÑO DE BLOQUE Y GRID*/
	int tamBlockX = 32;
	int tamBlockY = 8;;
	int tamGridX=0;
	int tamGridY=0;

	if (rows % tamBlockX == 0){
		tamGridX = rows / tamBlockX;
	} else {
		tamGridX = (rows / tamBlockX) + 1;
	}
	if (columns % tamBlockY == 0){
		tamGridY = columns / tamBlockY;
	} else {
		tamGridY = (columns / tamBlockY) + 1;
	}
	
	dim3 bloqTam(tamBlockX,tamBlockY); 
	dim3 gridTam(tamGridX,tamGridY);

	/*Tamaño de global_residual_salida*/
	float *maximos = (float *)malloc(sizeof(float)*(size_t)tamGridX*(size_t)tamGridY);
	float *dmaximos;

	/*tamaño de dsurface y dsurfacecopy*/
	cudaMalloc((void**) &dsurface, sizeof(float) * (size_t)rows * (size_t)columns);
	cudaMalloc((void**) &dsurfaceCopy, sizeof(float) * (size_t)rows * (size_t)columns);
	cudaMalloc((void**) &dmaximos, sizeof(float) * (size_t)tamGridX * (size_t)tamGridY);
	cudaMalloc((void**) &dfocal, sizeof(FocalPoint) *(size_t)num_focal);

	/* 3. Initialize surface */
	for( i=0; i<rows; i++ )
		for( j=0; j<columns; j++ )
			accessMat( surface, i, j ) = 0.0;

	/* 4. Simulation */
	int iter;
	int flag_stability = 0;
	int first_activation = 0;
	for( iter=0; iter<max_iter && ! flag_stability; iter++ ) {

		/* 4.1. Activate focal points */
		int num_deactivated = 0;
		for( i=0; i<num_focal; i++ ) {
			if ( focal[i].start == iter ) {
				focal[i].active = 1;
				if ( ! first_activation ) first_activation = 1;
			}
			// Count focal points already deactivated by a team
			if ( focal[i].active == 2 ) num_deactivated++;
		}

		/* 4.2. Propagate heat (10 steps per each team movement) */
		float global_residual = 0.0f;
		int step;
		
		cudaMemcpy(dsurface,surface,sizeof(float) * (size_t)rows * (size_t)columns, cudaMemcpyHostToDevice);
		cudaMemcpy(dfocal,focal,sizeof(FocalPoint) * (size_t)num_focal, cudaMemcpyHostToDevice);
		
		for( step=0; step<10; step++ )	{
			/* 4.2.1. Update heat on active focal points */
			//cudaMemcpy(dsurface,surface,sizeof(float) * (size_t)rows * (size_t)columns, cudaMemcpyHostToDevice);
			//cudaMemcpy(dfocal,focal,sizeof(FocalPoint) * (size_t)num_focal, cudaMemcpyHostToDevice);
			//puntosfocales<<<gridTam,bloqTam>>>(dsurface, dfocal, num_focal);

			
			//for( i=0; i<num_focal; i++ ) {
			//	if ( focal[i].active != 1 ) continue;
			//	int x = focal[i].x;
			//	int y = focal[i].y;
			//	accessMat( surface, x, y ) = focal[i].heat;
			//}
			heat<<<1,1>>>(dsurface, dfocal, num_focal, columns);

			/* 4.2.2. Copy values of the surface in ancillary structure (Skip borders) */
			/*for( i=1; i<rows-1; i++ )
				for( j=1; j<columns-1; j++ )
					accessMat( surfaceCopy, i, j ) = accessMat( surface, i, j );
			*/
			
			//copia<<<gridTam,bloqTam>>>(dsurface,dsurfaceCopy,rows, columns);
			
			//cudaMemcpy(dsurface,surface,sizeof(float) * (size_t)rows * (size_t)columns, cudaMemcpyHostToDevice);
			float *temp = dsurface;
			dsurface = dsurfaceCopy;
			dsurfaceCopy = temp;

			/* 4.2.3. Update surface values (skip borders) */
			/*for( i=1; i<rows-1; i++ )
				for( j=1; j<columns-1; j++ )
					accessMat( surface, i, j ) = ( 
						accessMat( surfaceCopy, i-1, j ) +
						accessMat( surfaceCopy, i+1, j ) +
						accessMat( surfaceCopy, i, j-1 ) +
						accessMat( surfaceCopy, i, j+1 ) ) / 4;
			*/
			updatesurface<<<gridTam,bloqTam>>>(dsurface, dsurfaceCopy, rows, columns);
			//cudaMemcpy(surface, dsurface, sizeof(float) * (size_t)rows * (size_t)columns, cudaMemcpyDeviceToHost);

			if(step==0){
				int tamSize = sizeof(float) * tamBlockX * tamBlockY;

				reduce<256><<<gridTam,bloqTam,tamSize>>>(dsurface, dsurfaceCopy, dmaximos, rows, columns);
				cudaMemcpy(maximos, dmaximos, sizeof(float) * (size_t)tamGridX * (size_t)tamGridY, cudaMemcpyDeviceToHost);
					
				for(int i=0; i<(tamGridX*tamGridY);i++){
					if(maximos[i]>global_residual){
						global_residual=maximos[i];
					}
				}

			}

			//cudaMemcpy(surface,dsurface,sizeof(float) * (size_t)rows * (size_t)columns, cudaMemcpyDeviceToHost);
			/* 4.2.4. Compute the maximum residual difference (absolute value) */
			/*for( i=1; i<rows-1; i++ )
				for( j=1; j<columns-1; j++ ) 
					if ( fabs( accessMat( surface, i, j ) - accessMat( surfaceCopy, i, j ) ) > global_residual ) {
						global_residual = fabs( accessMat( surface, i, j ) - accessMat( surfaceCopy, i, j ) );
					}
			*/
		}
	
		cudaMemcpy(surface, dsurface, sizeof(float) * (size_t)rows * (size_t)columns, cudaMemcpyDeviceToHost);
		/* If the global residual is lower than THRESHOLD, we have reached enough stability, stop simulation at the end of this iteration */
		if( global_residual < THRESHOLD && num_deactivated == num_focal ) flag_stability = 1;

		/* 4.3. Move teams */
		for( t=0; t<num_teams; t++ ) {
			/* 4.3.1. Choose nearest focal point */
			float distance = FLT_MAX;
			int target = -1;
			for( j=0; j<num_focal; j++ ) {
				if ( focal[j].active != 1 ) continue; // Skip non-active focal points
				float dx = focal[j].x - teams[t].x;
				float dy = focal[j].y - teams[t].y;
				float local_distance = ( dx*dx + dy*dy );
				if ( local_distance < distance ) {
					distance = local_distance;
					target = j;
				}
			}
			/* 4.3.2. Annotate target for the next stage */
			teams[t].target = target;

			/* 4.3.3. No active focal point to choose, no movement */
			if ( target == -1 ) continue; 

			/* 4.3.4. Move in the focal point direction */
			if ( teams[t].type == 1 ) { 
				// Type 1: Can move in diagonal
				if ( focal[target].x < teams[t].x ) teams[t].x--;
				if ( focal[target].x > teams[t].x ) teams[t].x++;
				if ( focal[target].y < teams[t].y ) teams[t].y--;
				if ( focal[target].y > teams[t].y ) teams[t].y++;
			}
			else if ( teams[t].type == 2 ) { 
				// Type 2: First in horizontal direction, then in vertical direction
				if ( focal[target].y < teams[t].y ) teams[t].y--;
				else if ( focal[target].y > teams[t].y ) teams[t].y++;
				else if ( focal[target].x < teams[t].x ) teams[t].x--;
				else if ( focal[target].x > teams[t].x ) teams[t].x++;
			}
			else {
				// Type 3: First in vertical direction, then in horizontal direction
				if ( focal[target].x < teams[t].x ) teams[t].x--;
				else if ( focal[target].x > teams[t].x ) teams[t].x++;
				else if ( focal[target].y < teams[t].y ) teams[t].y--;
				else if ( focal[target].y > teams[t].y ) teams[t].y++;
			}
		}

		/* 4.4. Team actions */
		for( t=0; t<num_teams; t++ ) {
			/* 4.4.1. Deactivate the target focal point when it is reached */
			int target = teams[t].target;
			if ( target != -1 && focal[target].x == teams[t].x && focal[target].y == teams[t].y 
				&& focal[target].active == 1 )
				focal[target].active = 2;

			/* 4.4.2. Reduce heat in a circle around the team */
			int radius;
			// Influence area of fixed radius depending on type
			if ( teams[t].type == 1 ) radius = RADIUS_TYPE_1;
			else radius = RADIUS_TYPE_2_3;
			for( i=teams[t].x-radius; i<=teams[t].x+radius; i++ ) {
				for( j=teams[t].y-radius; j<=teams[t].y+radius; j++ ) {
					if ( i<1 || i>=rows-1 || j<1 || j>=columns-1 ) continue; // Out of the heated surface
					float dx = teams[t].x - i;
					float dy = teams[t].y - j;
					float distance = ( dx*dx + dy*dy );
					if ( distance <= radius*radius ) {
						accessMat( surface, i, j ) = accessMat( surface, i, j ) * ( 1 - 0.25 ); // Team efficiency factor
					}
				}
			}
		}

#ifdef DEBUG
		/* 4.5. DEBUG: Print the current state of the simulation at the end of each iteration */
		print_status( iter, rows, columns, surface, num_teams, teams, num_focal, focal, global_residual );
#endif // DEBUG
	}
	
/*
 *
 * STOP HERE: DO NOT CHANGE THE CODE BELOW THIS POINT
 *
 */

	/* 5. Stop global time */
	cudaDeviceSynchronize();
	ttotal = cp_Wtime() - ttotal;

	/* 6. Output for leaderboard */
	printf("\n");
	/* 6.1. Total computation time */
	printf("Time: %lf\n", ttotal );
	/* 6.2. Results: Number of iterations, position of teams, residual heat on the focal points */
	printf("Result: %d", iter);
	/*
	for (i=0; i<num_teams; i++)
		printf(" %d %d", teams[i].x, teams[i].y );
	*/
	for (i=0; i<num_focal; i++)
		printf(" %.6f", accessMat( surface, focal[i].x, focal[i].y ) );
	printf("\n");

	/* 7. Free resources */	
	free( teams );
	free( focal );
	free( surface );
	free( surfaceCopy );

	/* 8. End */
	return 0;
}

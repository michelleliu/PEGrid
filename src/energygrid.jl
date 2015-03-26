###
#  Author: Cory M. Simon (CoryMSimon@gmail.com)
###
include("framework.jl")
include("forcefield.jl")
include("energyutils.jl")
using Optim


function writegrid(adsorbate::String, structurename::String, forcefieldname::String; gridspacing=0.1, cutoff=12.5)
    """
    Compute the potential energy of an adsorbate molecule on a 3D grid of points superimposed on the unit cell of the structure.

    The grid is written to a file `structurename.cube`, in Gaussian cube format. The units of the energy are kJ/mol.

    :param: String adsorbate: the name of the adsorbate molecule, corresponding to the forcefield file
    """
    @printf("Constructing framework object for %s...\n", structurename)
    framework = Framework(structurename)

    @printf("Constructing forcefield object for %s...\n", forcefieldname)
    forcefield = Forcefield(forcefieldname, adsorbate, cutoff=cutoff)
    
    # get unit cell replication factors for periodic BCs
    rep_factors = get_replication_factors(framework.f_to_cartesian_mtrx, cutoff)
    @printf("Unit cell replication factors for LJ cutoff of %.2f A: %d by %d by %d\n", forcefield.cutoff, rep_factors[1], rep_factors[2], rep_factors[3])
    # how many grid points in each direction? 
    N_x = int(framework.a / gridspacing) + 1
    N_y = int(framework.b / gridspacing) + 1
    N_z = int(framework.c / gridspacing) + 1
    @printf("Grid is %d by %d by %d points, a total of %d grid points.\n", N_x, N_y, N_z, N_x*N_y*N_z)
    # fractional grid point spacing. Think of grid points as center of voxels.
    dx_f = 1.0 / (N_x - 1)
    dy_f = 1.0 / (N_y - 1)
    dz_f = 1.0 / (N_z - 1)
    @printf("Fractional grid spacing: dx_f = %f, dy_f = %f, dz_f = %f\n", dx_f, dy_f, dz_f)

    # get fractional coords of energy grid. 
    xf_grid = linspace(0.0, 1.0, N_x)
    yf_grid = linspace(0.0, 1.0, N_y)
    zf_grid = linspace(0.0, 1.0, N_z)
    
    # get grid point spacing in Cartesian space, just for kicks ^.^
    cartesian_spacing = framework.f_to_cartesian_mtrx * [xf_grid[2]-xf_grid[1], yf_grid[2]-yf_grid[1], zf_grid[2]-zf_grid[1]]
    @printf("Grid spacing: dx = %.2f, dy = %.2f, dz = %.2f\n", cartesian_spacing[1], cartesian_spacing[2], cartesian_spacing[3])

    # get array of framework atom positions and corresponding epsilons and sigmas for speed
    pos_array, epsilons, sigmas = _generate_pos_array_epsilons_sigmas(framework, forcefield)
    
    # open grid file
    if ! isdir(homedir() * "/PEGrid_output/" * forcefieldname)
       mkdir(homedir() * "/PEGrid_output/" * forcefieldname) 
    end
    gridfilename = homedir() * "/PEGrid_output/" * forcefieldname * "/" * framework.structurename * "_" * forcefield.adsorbate * ".cube"
    gridfile = open(gridfilename, "w")

    # Format of .cube described here http://paulbourke.net/dataformats/cube/
    write(gridfile, "This is a grid file generated by PEviz\nLoop order: x, y, z\n")
    @printf(gridfile, "%d %f %f %f\n" , 0, 0.0, 0.0, 0.0)  # 0 atoms, then origin
    # TODO list atoms in the crystal structure
    @printf(gridfile, "%d %f %f %f\n" , N_x, framework.f_to_cartesian_mtrx[1,1] / (N_x - 1), 0.0, 0.0)  # N_x, vector along x-edge of voxel
    @printf(gridfile, "%d %f %f %f\n" , N_y, framework.f_to_cartesian_mtrx[1,2] / (N_y - 1), framework.f_to_cartesian_mtrx[2,2] / (N_y - 1), 0.0)  # N_y, vector along y-edge of voxel
    @printf(gridfile, "%d %f %f %f\n" , N_z, framework.f_to_cartesian_mtrx[1,3] / (N_z - 1), framework.f_to_cartesian_mtrx[2,3] / (N_z - 1), framework.f_to_cartesian_mtrx[3,3] / (N_z - 1))

    @printf("Writing grid...\n")
    # loop over [fractional] grid points, compute energies
    for i in 1:N_x  # loop over x_f-grid points
        # print progress
        if i % (int(N_x/10.0)) == 0
            @printf("\tPercent finished: %.1f\n", 100.0*i/N_x)
        end

        for j in 1:N_y  # loop over y_f-grid points
            for k in 1:N_z  # loop over z_f-grid points

                E = _E_vdw_at_point!(xf_grid[i], yf_grid[j], zf_grid[k], 
                                    pos_array, epsilons, sigmas, 
                                    framework,
                                    rep_factors, cutoff)
                
                # write energy at this point to grid file
                @printf(gridfile, "%e ", E * 8.314 / 1000.0)  # store in kJ/mol
                if (k % 6) == 0
                    @printf(gridfile, "\n")
                end

            end # end loop in z_f-grid points
            @printf(gridfile, "\n")
        end # end loop in y_f-grid points
    end # end loop in x_f-grid points
    close(gridfile)
    @printf("\tDone.\nGrid available in %s\n", gridfilename)
end

type Grid
    """
    For interally storing energy grid
    """
    structurename::String
    forcefieldname::String

    # number of grid points
    N_x::Int
    N_y::Int
    N_z::Int

    # fractional grid spacing
    dx_f::Float64
    dy_f::Float64
    dz_f::Float64

    # store 3D array of energies here
    energies::Array{Float64}

    # functions
    energy_at::Function  # get energy at a point in fractional space
    min_energy::Function  # get minimum energy among grid points
    index_to_fractional_coord::Function

    function Grid(adsorbate::String, structurename::String, forcefieldname::String)
        """
        Constructor for Grid. Loads previously written cube file
        """
        grid = new()

        grid.structurename = structurename
        grid.forcefieldname = forcefieldname

        ###
        # load grid file
        ###
        gridfile = open(homedir() * "/PEGrid_output/" * forcefieldname * "/" * structurename * "_" * adsorbate * ".cube")
        readline(gridfile)  # waste
        readline(gridfile)  # waste
        readline(gridfile)  # waste

        grid.N_x = int(split(readline(gridfile))[1])
        grid.N_y = int(split(readline(gridfile))[1])
        grid.N_z = int(split(readline(gridfile))[1])
        @printf("N_x = %d, N_y = %d, N_z = %d\n", grid.N_x, grid.N_y, grid.N_z)

        grid.energies = zeros((grid.N_x, grid.N_y, grid.N_z))  # 3D array
        
        grid.dx_f = 1.0 / (grid.N_x - 1)
        grid.dy_f = 1.0 / (grid.N_y - 1)
        grid.dz_f = 1.0 / (grid.N_z - 1)
       
        line = readline(gridfile)  
        counter = 1
        for i in 1:grid.N_x  # loop over x_f-grid points
            for j in 1:grid.N_y  # loop over y_f-grid points
                for k in 1:grid.N_z  # loop over z_f-grid points

                    grid.energies[i, j, k] = float(split(line)[counter])
                    counter += 1
                    
                    if (k % 6) == 0
                        counter = 1
                        line = readline(gridfile)
                    end
                end # end loop in z_f-grid points
                line = readline(gridfile)
                counter = 1
            end # end loop in y_f-grid points
        end # end loop in x_f-grid points

        grid.min_energy = function()
            """
            Get minimum energy, index in grid, and frational coords at minimim energy in grid
            """
            idx_max = indmin(grid.energies)  # 1D
            minE = grid.energies[idx_max]
            i_max, j_max, k_max = ind2sub(size(grid.energies), idx_max)

            x_f = ([i_max, j_max, k_max] - 1) .* [grid.dx_f, grid.dy_f, grid.dz_f]  # fractional coordinate here
            return [i_max, j_max, k_max], minE, x_f
        end

        grid.energy_at = function(x_f::Float64, y_f::Float64, z_f::Float64)
            """
            Get energy at fractional coord x_f, y_f, z_f
            """
            @assert((x_f >= 0.0) & (y_f >= 0.0) & (z_f >= 0.0))
            @assert((x_f <= 1.0) & (y_f <= 1.0) & (z_f <= 1.0))

            # define indices of 8 grid points on the vertices of the cube surrounding
            # the pt (x_f, y_f, z_f) 
            i_x_low = ifloor(x_f / grid.dx_f) + 1;
            i_y_low = ifloor(y_f / grid.dy_f) + 1;
            i_z_low = ifloor(z_f / grid.dz_f) + 1;
            
            #trilinear interpolation http://en.wikipedia.org/wiki/Trilinear_interpolation
            # difference between our point and the vertex
            x_d = (x_f - (i_x_low-1) * grid.dx_f) / grid.dx_f
            y_d = (y_f - (i_y_low-1) * grid.dy_f) / grid.dy_f
            z_d = (z_f - (i_z_low-1) * grid.dz_f) / grid.dz_f

            # smash cube in x direction
            c00 = (1 - x_d) * grid.energies[i_x_low, i_y_low  , i_z_low  ] + x_d * grid.energies[i_x_low+1, i_y_low  , i_z_low  ]
            c10 = (1 - x_d) * grid.energies[i_x_low, i_y_low+1, i_z_low  ] + x_d * grid.energies[i_x_low+1, i_y_low+1, i_z_low  ]
            c01 = (1 - x_d) * grid.energies[i_x_low, i_y_low  , i_z_low+1] + x_d * grid.energies[i_x_low+1, i_y_low  , i_z_low+1]
            c11 = (1 - x_d) * grid.energies[i_x_low, i_y_low+1, i_z_low+1] + x_d * grid.energies[i_x_low+1, i_y_low+1, i_z_low+1]

            # further smash cube in y direction
            c0 = c00 * (1.0 - y_d) + c10 * y_d
            c1 = c01 * (1.0 - y_d) + c11 * y_d

            # finally, linear interpolation in z direction
            return c0 * (1 - z_d) + c1 * z_d
        end  # end energy_at function

        grid.index_to_fractional_coord = function(i::Int, j::Int, k::Int)
            """
            Convert grid of index to fraction coord that it represents
            """
            return [grid.dx_f * (i-1), grid.dy_f * (j-1), grid.dz_f * (k-1)]
        end
        
        return grid
    end  # end constructor
end  # end Grid type
